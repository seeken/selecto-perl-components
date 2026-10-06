package Selecto::Components::ExportBudget;
use Mojo::Base -base, -signatures;
use Encode qw(encode);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_CREAT O_RDWR O_NOFOLLOW LOCK_EX LOCK_NB);
use File::Path qw(make_path);
use File::Spec ();
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use Mojo::IOLoop;
use Scalar::Util qw(weaken);

sub new ($class, $config, $engine, $controller) {
    my $self = bless {config => $config, started => clock_gettime(CLOCK_MONOTONIC),
        bytes => 0, rows => 0, locks => [], cancel_callbacks => []}, $class;
    my $dir = $config->export_lock_dir;
    make_path($dir, {mode => 0700}) unless -e $dir;
    die "Export lock directory must be private and owned by this user\n"
        if -l $dir || !-d $dir || (stat($dir))[4] != $< || ((stat($dir))[2] & 0077);
    my $actor = $config->export_actor ? $config->export_actor->($controller, $config) : 'shared';
    die "Invalid export actor\n" if !defined($actor) || ref($actor) || length($actor) > 512;
    # Fixed hashed buckets keep lock-file count finite. Collisions only reduce
    # concurrency; they never grant extra slots to another actor.
    my $bucket = hex(substr(sha256_hex($actor), 0, 2));
    for my $pool (['global', $config->max_concurrent_exports], ["actor-$bucket", $config->max_actor_exports]) {
        my $locked;
        for my $index (1 .. $pool->[1]) {
            my $file = File::Spec->catfile($dir, "$pool->[0]-$index.lock");
            sysopen(my $fh, $file, O_CREAT | O_RDWR | O_NOFOLLOW, 0600) or die "Cannot open export lease\n";
            if (flock($fh, LOCK_EX | LOCK_NB)) { push @{$self->{locks}}, $fh; $locked = 1; last }
            close $fh;
        }
        die "Export concurrency limit exceeded\n" unless $locked;
    }
    my $adapter = $engine->adapter;
    die "Adapter does not support bounded export execution\n"
        unless $adapter->can('bounded_stream_supported') && $adapter->bounded_stream_supported
            && $adapter->can('begin_query_budget') && $adapter->can('query_budget_supported') && $adapter->query_budget_supported;
    $self->{database} = $adapter->begin_query_budget(timeout_ms => $config->max_export_seconds * 1000);
    my $weak = $self;
    weaken($weak);
    $self->{timer} = Mojo::IOLoop->timer($self->remaining => sub { $weak->cancel if $weak });
    return $self;
}
sub check ($self) {
    die "Export was cancelled\n" if $self->{closed};
    die "Export time limit exceeded\n" if clock_gettime(CLOCK_MONOTONIC) - $self->{started} >= $self->{config}->max_export_seconds;
    # Exports' only blocking database work is the bounded stream's FETCH,
    # which refreshes the server timeout itself just before fetching.
    $self->{database}->check(defer_rearm => 1) if $self->{database};
}
sub row ($self, $row) {
    $self->check;
    die "Export row limit exceeded\n" if ++$self->{rows} > $self->{config}->max_export_rows;
    # Bound decoded cell/nested values before formatting or serialization.
    my ($size, $nodes) = (0,0);
    my $walk;
    $walk = sub ($value, $depth = 0) {
        die "Export cell nesting limit exceeded\n" if $depth > 16 || ++$nodes > 10_000;
        if (!ref($value)) {
            return unless defined $value;
            die "Export cell is too large\n" if length($value) > $self->{config}->max_export_bytes;
            $size += length(encode('UTF-8', "$value"));
        } elsif (ref($value) eq 'ARRAY') { $walk->($_,$depth+1) for @$value }
        elsif (ref($value) eq 'HASH') { for my $key (keys %$value) { $walk->($key,$depth+1); $walk->($value->{$key},$depth+1) } }
        else { die "Invalid export cell\n" }
        die "Export row is too large\n" if $size > $self->{config}->max_export_bytes;
    };
    $walk->($row);
}
sub output ($self, $value, $binary = 0) {
    $self->check;
    die "Export byte limit exceeded\n" if length($value) > $self->{config}->max_export_bytes;
    $self->{bytes} += $binary ? length($value) : length(encode('UTF-8', $value));
    die "Export byte limit exceeded\n" if $self->{bytes} > $self->{config}->max_export_bytes;
}
sub remaining ($self) {
    my $left = $self->{config}->max_export_seconds - (clock_gettime(CLOCK_MONOTONIC) - $self->{started});
    return $left > 0 ? $left : 0;
}
sub closed ($self) { return $self->{closed} ? 1 : 0 }
sub on_cancel ($self, $callback) {
    return $callback->() if $self->{cancelled};
    push @{$self->{cancel_callbacks}}, $callback unless $self->{closed};
}
sub cancel ($self) {
    return if $self->{closed} || $self->{cancelled}++;
    my @callbacks = @{$self->{cancel_callbacks}};
    $self->{cancel_callbacks} = [];
    eval { $_->() } for @callbacks;
    eval { $self->close };
}
sub close ($self) {
    return if $self->{closed}++;
    Mojo::IOLoop->remove(delete $self->{timer}) if defined $self->{timer};
    $self->{cancel_callbacks} = [];
    my $error;
    eval { $self->{database}->close if $self->{database}; 1 } or $error = $@;
    close $_ for @{$self->{locks}};
    $self->{locks} = [];
    die $error if $error;
}
sub DESTROY ($self) { local $@; eval { $self->close }; }
1;
