use 5.034;
use strict;
use warnings;
use utf8;
use Test::More;
use DBI ();
use Mojo::DOM ();
use lib 't/lib';
use TestSelectoComponents;
use Selecto;
use Selecto::Components::Config ();
use Selecto::Components::Explorer ();
use Selecto::Components::I18N ();
use Selecto::Components::Renderer ();

# Column and filter-choice descriptions (Selecto::Domain field_description)
# reach the field catalog, translated like labels, and the Explorer shows them
# beside the label: picker choices, chosen fields, filters and column headings.

plan skip_all => 'DBD::SQLite is not installed' unless eval { require DBD::SQLite; 1 };

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', undef, undef,
    {RaiseError => 1, PrintError => 0, AutoCommit => 1});
$dbh->do('CREATE TABLE orders (id integer primary key, total numeric, status text, secret text)');
$dbh->do(q{INSERT INTO orders VALUES (1, 10, 'A', 'x'), (2, 20, 'D', 'y')});

my $domain = Selecto::Domain->parse({
    schema_version => 1, name => 'Orders',
    source => {
        source_table => 'orders', primary_key => 'id', fields => [qw(id total status secret)],
        columns => {
            id => {type => 'integer'},
            total => {type => 'decimal', label => 'Total', description => 'What the customer pays.'},
            status => {type => 'string', label => 'Status'},
            secret => {type => 'string', internal => 1, description => 'Never shown.'},
        },
        associations => {},
    },
    schemas => {}, joins => {},
    components => {filter_choices => {status => {label => 'Status', description => 'Where the order stands.',
        choices => [{value => 'A', label => 'Active'}, {value => 'D', label => 'Delivered'}]}}},
}, strict => 1);

my %translations;
my $explorer = Selecto::Components::Explorer->new(config => Selecto::Components::Config->new(
    id => 'orders', title => 'Orders', path => '/explore/orders',
    engine_factory => sub { Selecto::Engine->new(domain => $domain, adapter => Selecto->adapter(sqlite => (dbh => $dbh))) },
    default_fields => [qw(id total status)],
    localizer => sub { my ($key, $default, $context) = @_; $translations{$context->{semantic}} // $default },
));
my $config = $explorer->config;

my %catalog = map { $_->{path} => $_ } @{$config->field_catalog($domain)};
is $catalog{total}{description}, 'What the customer pays.', 'the catalog carries a field\'s description';
ok !exists $catalog{status}{description}, 'and none without one';
ok !$catalog{secret}, 'internal fields stay out';
is $config->filter_map($domain)->{status}{description}, 'Where the order stands.', 'a filter choice\'s description';

# A domain declaring an i18n namespace lists its translation terms.
my $named = Selecto::Domain->parse({%{$domain->contract},
    extensions => {i18n => {namespace => 'test.orders', terms => {}}}}, strict => 1);
my %terms = map { $_->{semantic} => $_ } @{Selecto::Components::I18N->terms($named)};
is $terms{'fields.total.description'}{default}, 'What the customer pays.', 'descriptions are translation terms';
$translations{'fields.total.description'} = 'Ce que paie le client.';
my $translated = Selecto::Components::Config->new(
    id => 'orders', title => 'Orders', path => '/explore/orders', engine_factory => $config->engine_factory,
    localizer => $config->localizer,
);
is((grep { $_->{path} eq 'total' } @{$translated->field_catalog($named)})[0]{description},
    'Ce que paie le client.', 'and are translated like labels');
delete $translations{'fields.total.description'};

my $model = $explorer->model(TestSelectoComponents::Controller->new(params => {
    q => 1, view => 'detail', field => [qw(id total status)], order => 'id', limit => 25, page => 1,
    filter_field => 'status', filter_op => 'eq', filter_value => 'A', filter_promote_index => 0,
}));
ok $model->{state}->valid, 'the request is valid' or diag explain $model->{state}->errors;
my $dom = Mojo::DOM->new(Selecto::Components::Renderer->page($model));
my $total_th = $dom->find('th')->first(sub { $_->text eq 'Total' });
ok $total_th, 'the Total column heading';
is $total_th && $total_th->attr('title'), 'What the customer pays.', 'shows the description as its title';
like $total_th && $total_th->attr('class'), qr/sc-described/, 'marked as described';
my $status_th = $dom->find('th')->first(sub { $_->text eq 'Status' });
ok $status_th && !defined($status_th->attr('title')), 'a heading without a description has no title';
my $set_item = $dom->at('[data-sc-picker-set-item][data-field="total"]');
ok $set_item, 'the chosen Total field';
is $set_item && $set_item->attr('data-description'), 'What the customer pays.', 'carries its description';
is $set_item && $set_item->at('.sc-field-description')->text, 'What the customer pays.', 'and shows it';
my $filter = $dom->at('[data-sc-filter-set-item][data-field="status"]') // $dom->at('[data-sc-promoted-filter][data-field="status"]');
ok $filter, 'the Status filter';
is $filter && $filter->at('.sc-field-description') && $filter->at('.sc-field-description')->text,
    'Where the order stands.', 'shows the filter choice\'s description';
unlike $dom->to_string, qr/Never shown/, 'an internal field\'s description is never rendered';

done_testing;
