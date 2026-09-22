use 5.034;
use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/lib";
use JSON::PP ();
use Test::More;
use TestSelectoComponents ();
use Selecto::Components::Templates::SourceExecutor;
use Selecto::Domain ();
use Selecto::Engine ();
use Selecto::Expression ();
use Selecto::PostgreSQL ();
use Selecto::Templates ();

my $manifest = TestSelectoComponents::template_order_manifest();
my $catalog = TestSelectoComponents::template_domain_catalog();
my $effect = Selecto::Templates->mount_runtime(
    $manifest,
    instance_id => 'source-executor-perl',
    release_id => 'source-executor-release',
    inputs => {},
)->{effects}[0];
$effect->{bindings}{state}{search} = 'PO-100';

my $dbh = TemplateSourceDBH->new(
    rows => [[1, 'PO-100', '2026-09-21T12:00:00Z', 'open', 44]],
    pg_type => [qw(int4 text timestamptz text int4)],
);
my $authorization_calls = 0;
my $authorize = sub {
    my ($source, $received_effect) = @_;
    $authorization_calls++;
    is $source->{id}, 'orders', 'executor resolves the source from the server manifest';
    is $received_effect->{generation}, 1, 'authorization receives the data-only effect';

    my $domain = Selecto::Domain->parse($catalog->{domains}{orders}, strict => 1)
        ->with_required_predicate(Selecto::Expression->eq('tenant_id', 7));
    my $engine = Selecto::Engine->new(
        domain => $domain,
        adapter => Selecto::PostgreSQL->new(dbh => $dbh),
    );
    return {
        status => 'ok',
        engine => $engine,
        query => $engine->query
            ->where(Selecto::Expression->eq('status', 'open'))
            ->limit(10),
    };
};

my $executed = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
);
is $executed->{status}, 'ok', 'authorized source execution succeeds';
is $authorization_calls, 1, 'host authorization runs once for the effect';
is_deeply(
    $executed->{result},
    [{
        id => 1,
        order_number => 'PO-100',
        ordered_at => '2026-09-21T12:00:00',
        status => 'open',
        customer => {id => 44},
    }],
    'native positional rows are projected into portable source data',
);
my $prepared = $dbh->prepared->[0];
like $prepared->sql, qr/"s0"\."tenant_id"/, 'native SQL retains tenant scope';
ok scalar(grep { defined($_) && !ref($_) && $_ eq '7' } @{$prepared->params}),
    'tenant scope stays bound';
ok scalar(grep { defined($_) && !ref($_) && $_ eq 'open' } @{$prepared->params}),
    'host membership stays bound';
ok scalar(grep { defined($_) && !ref($_) && $_ eq 'PO-100' } @{$prepared->params}),
    'template search stays bound';

my $not_called = 0;
my $unknown = {%$effect, source => 'missing'};
my $unknown_result = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $unknown,
    authorize => sub { $not_called++; return undef },
);
is $unknown_result->{code}, 'unknown_source', 'unknown sources fail before authorization';
is $not_called, 0, 'unknown sources never reach host authorization';

my $denied = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => sub { return {status => 'error', token => 'must-not-escape'} },
);
is $denied->{code}, 'source_authorization_failed', 'authorization denial is bounded';
unlike(
    JSON::PP->new->canonical->encode($denied),
    qr/must-not-escape/,
    'authorization detail does not escape',
);

my $execution_failed = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    run => sub { die "password=must-not-escape\n" },
);
is $execution_failed->{code}, 'source_execution_failed', 'execution failure is bounded';
unlike(
    JSON::PP->new->canonical->encode($execution_failed),
    qr/must-not-escape/,
    'database detail does not escape',
);

my $invalid_rows = Selecto::Components::Templates::SourceExecutor->execute(
    manifest => $manifest,
    effect => $effect,
    authorize => $authorize,
    run => sub { return {rows => [[1]]} },
);
is $invalid_rows->{code}, 'invalid_source_result', 'invalid native rows fail projection';

done_testing;

package TemplateSourceDBH;

sub new {
    my ($class, %args) = @_;
    return bless {%args, prepared => []}, $class;
}

sub prepare {
    my ($self, $sql) = @_;
    my $statement = TemplateSourceSTH->new(owner => $self, sql => $sql);
    push @{$self->{prepared}}, $statement;
    return $statement;
}

sub errstr { return undef }
sub prepared { return [@{$_[0]->{prepared}}] }

package TemplateSourceSTH;

sub new {
    my ($class, %args) = @_;
    return bless {
        %args,
        index => 0,
        params => [],
        pg_type => $args{owner}{pg_type},
    }, $class;
}

sub execute {
    my ($self, @params) = @_;
    $self->{params} = [@params];
    return 1;
}

sub fetchrow_array {
    my ($self) = @_;
    return if $self->{index} >= @{$self->{owner}{rows}};
    return @{$self->{owner}{rows}[$self->{index}++]};
}

sub err { return undef }
sub errstr { return undef }
sub sql { return $_[0]->{sql} }
sub params { return [@{$_[0]->{params}}] }
