package Selecto::Components::RoundTrips;

# Database round trips for the Query Debug panel, counted from libpq's
# protocol trace (DBD::Pg pg_server_trace) on the adapter's handle while the
# Explorer model runs. Every round trip ends with the server's ReadyForQuery,
# so the count is exact, including what the driver sends unasked: the BEGIN
# before a statement when AutoCommit is off, or the Parse before a statement's
# second execute. Other adapters have no trace: start returns undef.

use Mojo::Base -base, -signatures;
use File::Temp ();
use Scalar::Util qw(blessed);

use constant MAX_LISTED => 50;
use constant MAX_COMMAND => 160;

# A tracer on the adapter's DBD::Pg handle, or undef.
sub start ($class, $adapter) {
    my $dbh = blessed($adapter) && $adapter->can('dbh') ? eval { $adapter->dbh } : undef;
    return undef unless blessed($dbh) && eval { ($dbh->{Driver}{Name} // '') eq 'Pg' };
    my ($write, $path) = File::Temp::tempfile('selecto-round-trips-XXXXXX', TMPDIR => 1, UNLINK => 0);
    my $read;
    unless (open $read, '<', $path) {
        unlink $path;
        return undef;
    }
    # The trace holds row values: the file keeps no name on disk.
    unlink $path;
    my $self = $class->new(dbh => $dbh, write => $write, read => $read, phase => 'other', partial => '',
        trips => [], open_trip => undef, sent_bytes => 0, received_bytes => 0);
    return undef unless eval { $dbh->pg_server_trace($write); 1 };
    $self->{tracing} = 1;
    return $self;
}

# Runs $code (in scalar context) with its round trips counted as $phase.
sub during ($self, $phase, $code) {
    $self->_switch($phase);
    my $result;
    my $ok = eval { $result = $code->(); 1 };
    my $error = $@;
    $self->_switch('other');
    die $error unless $ok;
    return $result;
}

# Stops tracing: {total, phases => {phase => count}, wait_ms, sent_bytes,
# received_bytes, trips => [{phase, ms, command}] (at most MAX_LISTED)}.
sub finish ($self) {
    $self->_stop;
    $self->_read;
    close $self->{read};
    close $self->{write};
    my @trips = @{$self->{trips}};
    my %phases;
    $phases{$_->{phase}}++ for @trips;
    my $wait = 0;
    $wait += $_->{ms} for @trips;
    return {
        total => scalar(@trips),
        phases => \%phases,
        wait_ms => _round($wait),
        sent_bytes => $self->{sent_bytes},
        received_bytes => $self->{received_bytes},
        trips => [map { {%$_, ms => _round($_->{ms})} } @trips[0 .. ($#trips < MAX_LISTED ? $#trips : MAX_LISTED - 1)]],
    };
}

sub DESTROY ($self, @) { $self->_stop }

# libpq flushes the trace when it stops, so the lines so far are read and
# credited to the phase they ran in before the next one starts.
sub _switch ($self, $phase) {
    return unless $self->{tracing};
    $self->_stop;
    $self->_read;
    $self->{phase} = $phase;
    $self->{tracing} = eval { $self->{dbh}->pg_server_trace($self->{write}); 1 } ? 1 : 0;
}

sub _stop ($self) {
    return unless $self->{tracing};
    $self->{tracing} = 0;
    eval { $self->{dbh}->pg_server_untrace };
}

sub _read ($self) {
    my $fh = $self->{read};
    while (defined(my $line = <$fh>)) {
        $line = $self->{partial} . $line;
        $self->{partial} = '';
        unless ($line =~ s/\n\z//) {
            $self->{partial} = $line;
            last;
        }
        $self->_line($line);
    }
    seek $fh, 0, 1;   # (clears EOF, so later lines are read)
}

# "<timestamp>\t<F|B>\t<length>\t<message>[\t <arguments>]", one message a
# line: F from the client, B from the server. A message is its length plus
# its type byte on the wire.
sub _line ($self, $line) {
    my ($time, $direction, $length, $type, $arguments) = split /\t/, $line, 5;
    return unless defined($type) && $length =~ /\A\d+\z/;
    my $at = _seconds($time);
    if ($direction eq 'F') {
        $self->{sent_bytes} += $length + 1;
        $self->{open_trip} //= {phase => $self->{phase}, started => $at,
            command => _command($type, $arguments // '')};
    } elsif ($direction eq 'B') {
        $self->{received_bytes} += $length + 1;
        return unless $type eq 'ReadyForQuery' && (my $trip = delete $self->{open_trip});
        my $ms = defined($at) && defined($trip->{started}) ? ($at - $trip->{started}) * 1000 : 0;
        $ms += 86_400_000 if $ms < 0;   # (past midnight)
        push @{$self->{trips}}, {phase => $trip->{phase}, ms => $ms, command => $trip->{command}};
    }
}

# What a round trip sent, from its first message: a simple query's text, an
# extended query's SQL, or the prepared statement it ran.
sub _command ($type, $arguments) {
    my $command = $type;
    if ($type eq 'Query' && $arguments =~ /\A ?"(.*)"\z/s) {
        $command = $1;
    } elsif ($type eq 'Parse' && $arguments =~ /\A ?"[^"]*" "(.*)" \d+(?: \d+)*\z/s) {
        $command = $1;
    } elsif ($type eq 'Bind' && $arguments =~ /\A ?"[^"]*" "([^"]+)"/) {
        $command = "Prepared statement $1";
    }
    $command =~ s/\s+/ /g;
    $command =~ s/\A | \z//g;
    $command = substr($command, 0, MAX_COMMAND - 1) . '…' if length($command) > MAX_COMMAND;
    return $command;
}

sub _seconds ($time) {
    return undef unless defined($time) && $time =~ /(\d\d):(\d\d):(\d\d(?:\.\d+)?)\z/;
    return $1 * 3600 + $2 * 60 + $3;
}

sub _round ($ms) { return 0 + sprintf('%.2f', $ms) }

1;

=head1 NAME

Selecto::Components::RoundTrips - database round trips for the Query Debug panel

=head1 SYNOPSIS

  my $trips = Selecto::Components::RoundTrips->start($engine->adapter);
  my $raw = $trips ? $trips->during(data => sub { $engine->execute(...) }) : ...;
  my $summary = $trips && $trips->finish;

=head1 DESCRIPTION

Counts the round trips the Explorer makes on its PostgreSQL handle while the
Explorer model runs, from libpq's protocol trace. Each round trip ends with
the server's C<ReadyForQuery>, so the count includes what the driver sends
on its own: the C<BEGIN> before a statement when C<AutoCommit> is off, and
the C<Parse> before a statement's second execute. Only the handle the adapter
queries is traced; a host's other connections are not.

The trace includes row values. It is written to an unnamed temporary file
(created, opened and unlinked at once) and is used only when C<show_sql> is
on.

C<start> returns undef for adapters without a C<DBD::Pg> handle.
C<during($phase, $code)> credits the round trips C<$code> makes to C<$phase>;
the rest are C<other>. C<finish> stops tracing and returns C<total>,
C<phases> (counts by phase), C<wait_ms> (time from each round trip's first
message to the server's C<ReadyForQuery>), C<sent_bytes>, C<received_bytes>
and the first 50 C<trips> (C<phase>, C<ms>, C<command>: the query text, the
SQL parsed, or the prepared statement run, at most 160 characters).

=cut
