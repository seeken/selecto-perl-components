package Selecto::Components::Explorer;

use Mojo::Base -base, -signatures;
use Mojo::URL ();
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use Selecto::Components::QueryBuilder ();
use Selecto::Components::State ();

has 'config';

sub input_from_controller ($self, $controller) {
    my %input;
    for my $name (@{Selecto::Components::State->parameter_names}) {
        my @values = $controller->every_param($name);
        next unless @values;
        $input{$name} = @values == 1 ? $values[0] : \@values;
    }
    return \%input;
}

sub model ($self, $controller, $input = undef) {
    my $input_supplied = defined $input;
    my $engine;
    my $state;
    my $model = {
        config => $self->config,
        input => undef,
        result => undef,
        runtime_error => undef,
    };
    my $ok = eval {
        $engine = $self->config->engine($controller);
        $input = $input_supplied || $self->config->query_params_enabled($engine->domain)
            ? ($input // $self->input_from_controller($controller))
            : {};
        $model->{input} = $input;
        $state = Selecto::Components::State->from_input(
            $self->config, $engine->domain, $input
        );
        $model->{engine} = $engine;
        $model->{domain} = $engine->domain;
        $model->{state} = $state;
        $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        return 1 unless $state->valid;

        my $built = Selecto::Components::QueryBuilder->build(
            $self->config, $engine->domain, $state
        );
        my $started = time;
        my $statement = $engine->compile($built->{query});
        my $raw = $engine->adapter->execute_query($statement);
        my $elapsed_ms = int((time - $started) * 1000 + 0.5);
        _validate_result($raw);
        my @records = map {
            my %record;
            @record{@{$raw->{columns}}} = @$_;
            \%record;
        } @{$raw->{rows}};
        $model->{result} = {
            %$built,
            columns => $built->{columns},
            records => \@records,
            rows => [map { [@$_] } @{$raw->{rows}}],
            result_columns => [@{$raw->{columns}}],
            count => scalar(@records),
            has_more => @records == $state->limit ? 1 : 0,
            elapsed_ms => $elapsed_ms,
            adapter_name => $engine->adapter->name,
            ($self->config->show_sql ? (
                sql => $statement->sql,
                params => $statement->params,
            ) : ()),
        };
        1;
    };
    unless ($ok) {
        my $error = $@;
        $model->{runtime_error} = _public_error($error);
        if (!$state && $engine) {
            $state = Selecto::Components::State->from_input(
                $self->config, $engine->domain, {}
            );
            $model->{state} = $state;
            $model->{domain} = $engine->domain;
            $model->{canonical_url} = $self->canonical_url($state, $engine->domain);
        }
    }
    return $model;
}

sub canonical_url ($self, $state, $domain = undef) {
    return $self->config->path
        if $domain && !$self->config->query_params_enabled($domain);
    my $url = Mojo::URL->new($self->config->path);
    $url->query($state->query_pairs);
    return $url->to_string;
}

sub csv ($self, $model) {
    die "cannot export an invalid query\n"
        unless $model->{state} && $model->{state}->valid && $model->{result};
    my @lines;
    push @lines, join(',', map { _csv_cell($_->{label}) } @{$model->{result}{columns}});
    for my $record (@{$model->{result}{records}}) {
        push @lines, join(',', map { _csv_cell($record->{$_->{key}}) } @{$model->{result}{columns}});
    }
    return join("\r\n", @lines) . "\r\n";
}

sub _validate_result ($result) {
    die "adapter returned an invalid result\n" unless ref($result) eq 'HASH';
    die "adapter result columns must be an array\n" unless ref($result->{columns}) eq 'ARRAY';
    die "adapter result rows must be an array\n" unless ref($result->{rows}) eq 'ARRAY';
    for my $row (@{$result->{rows}}) {
        die "adapter result row must be an array\n" unless ref($row) eq 'ARRAY';
        die "adapter result row width does not match columns\n"
            unless @$row == @{$result->{columns}};
    }
}

sub _public_error ($error) {
    return $error->message if blessed($error) && $error->isa('Selecto::Error');
    return 'The governed query could not be completed.';
}

sub _csv_cell ($value) {
    $value = '' unless defined $value;
    $value = "$value";
    $value = "'$value" if $value =~ /\A[=+\-@]/;
    $value =~ s/"/""/g;
    return qq{"$value"};
}

1;
