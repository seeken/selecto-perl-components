package Selecto::Components::RowActions;

use Mojo::Base -base, -signatures;
use Mojo::Util qw(url_escape);
use Selecto::Components::Util qw(trim);

sub catalog ($class, $domain, $config = undef) {
    return [] unless $domain && $domain->can('detail_actions');
    my $actions = $domain->detail_actions;
    return [] unless ref($actions) eq 'HASH';
    my @catalog;
    for my $id (sort keys %$actions) {
        my $action = $actions->{$id};
        next unless ref($action) eq 'HASH'
            && ($action->{type} // '') =~ /\A(?:external_link|iframe_modal)\z/;
        my $name = "$action->{name}";
        $name = $config->localize(
            $domain, "detail_actions.$id.name", $name,
            {kind => 'detail_action', id => $id, attribute => 'name'},
        ) if $config;
        push @catalog, {%$action, id => $id, name => $name};
    }
    @catalog = sort {
        lc($a->{name}) cmp lc($b->{name}) || $a->{id} cmp $b->{id}
    } @catalog;
    return \@catalog;
}

sub find ($class, $domain, $id, $config = undef) {
    return undef unless defined($id) && !ref($id) && length("$id");
    for my $action (@{$class->catalog($domain, $config)}) {
        return {%$action} if $action->{id} eq "$id";
    }
    return undef;
}

sub resolve ($class, $action, $record, $fields) {
    return undef unless ref($action) eq 'HASH'
        && ref($action->{payload}) eq 'HASH'
        && ref($record) eq 'HASH' && ref($fields) eq 'ARRAY';
    my $type = $action->{type} // '';
    return undef unless $type eq 'external_link' || $type eq 'iframe_modal';
    my %value_by_field;
    for my $field (@$fields) {
        return undef unless ref($field) eq 'HASH'
            && defined($field->{field}) && defined($field->{key});
        my $value = $record->{$field->{key}};
        return undef if !defined($value) || ref($value);
        $value_by_field{$field->{field}} = "$value";
    }
    my $url = _resolve_template($action->{payload}{url_template}, \%value_by_field, 1);
    return undef unless defined $url;
    $url = $class->safe_url($url);
    return undef unless defined $url;
    if ($type eq 'external_link') {
        my $target = $action->{payload}{target} // '_self';
        $target = '_self'
            unless !ref($target) && "$target" =~ /\A_(?:self|blank|parent|top)\z/;
        return {type => $type, url => $url, target => "$target"};
    }
    my $title = _resolve_template(
        $action->{payload}{title} // $action->{name} // 'Details',
        \%value_by_field, 0,
    );
    return undef unless defined $title;
    my $size = $action->{payload}{size} // 'xl';
    $size = 'xl' unless !ref($size)
        && "$size" =~ /\A(?:sm|md|lg|xl|full|third|fullscreen)\z/;
    my $referrer_policy = $action->{payload}{referrer_policy}
        // 'strict-origin-when-cross-origin';
    $referrer_policy = 'strict-origin-when-cross-origin'
        unless !ref($referrer_policy)
        && "$referrer_policy" =~ /\A(?:no-referrer|no-referrer-when-downgrade|origin|origin-when-cross-origin|same-origin|strict-origin|strict-origin-when-cross-origin|unsafe-url)\z/;
    my %resolved = (
        type => $type,
        url => $url,
        title => $title,
        size => "$size",
        referrer_policy => "$referrer_policy",
        navigation_enabled => exists($action->{payload}{navigation_enabled})
            ? ($action->{payload}{navigation_enabled} ? 1 : 0) : 1,
    );
    for my $key (qw(allow sandbox)) {
        my $setting = $action->{payload}{$key};
        next unless defined($setting) && !ref($setting)
            && length("$setting") && "$setting" !~ /[\x00-\x1f\x7f<>"'`]/;
        $resolved{$key} = "$setting";
    }
    return \%resolved;
}

sub resolve_external_link ($class, $action, $record, $fields) {
    my $resolved = $class->resolve($action, $record, $fields);
    return undef unless $resolved && $resolved->{type} eq 'external_link';
    return {url => $resolved->{url}, target => $resolved->{target}};
}

sub resolve_iframe_modal ($class, $action, $record, $fields) {
    my $resolved = $class->resolve($action, $record, $fields);
    return undef unless $resolved && $resolved->{type} eq 'iframe_modal';
    return $resolved;
}

sub _resolve_template ($template, $values, $escape) {
    return undef unless defined($template) && !ref($template);
    my $resolved = "$template";
    my $complete = 1;
    $resolved =~ s/\{\{\s*([^}]+?)\s*\}\}/_template_value($values, $1, \$complete, $escape)/ge;
    return undef unless $complete;
    return $resolved;
}

sub _template_value ($values, $field, $complete, $escape) {
    unless (exists $values->{$field}) {
        $$complete = 0;
        return '';
    }
    return $escape ? url_escape($values->{$field}) : $values->{$field};
}

sub safe_url ($class, $value) {
    return undef if !defined($value) || ref($value);
    my $url = trim("$value");
    return undef unless length($url);
    return undef if $url =~ /\x00/ || $url =~ m{\A//}
        || $url =~ /\A(?:javascript|data|vbscript):/i
        || $url =~ /\A(?!https?:)[A-Za-z][A-Za-z0-9+.-]*:/i;
    return $url;
}

1;
