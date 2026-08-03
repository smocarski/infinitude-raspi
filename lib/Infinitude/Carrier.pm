package Infinitude::Carrier;

# Pushes locally-made changes up to Carrier's cloud.
#
# Carrier authenticates *thermostats* with OAuth 1.0a HMAC-SHA1 signed by
# secrets held in firmware, so Infinitude cannot impersonate the stat. It can
# however authenticate as the *account owner*, which is what Carrier's own
# mobile app does, and that path accepts writes. Carrier then pushes the change
# down to the thermostat through the existing carrier_changes path.
#
# Local writes are never gated on this succeeding: callers apply the change
# locally first and only then mark a field dirty here. If Carrier is
# unreachable the change still reaches the thermostat, which is the whole point
# of Infinitude sitting in the middle.

use strict;
use warnings;
use feature ':5.10';

use Mojo::JSON qw/encode_json/;
use Mojo::UserAgent;
use Mojo::IOLoop;
use Mojo::Promise;
use Digest::MD5 qw/md5_hex/;
use Try::Tiny;
use XML::Simple::Minded;

our $LOGIN_URL = 'https://dataservice.infinity.iot.carrier.com/graphql-no-auth';
our $GQL_URL   = 'https://dataservice.infinity.iot.carrier.com/graphql';
our $SSO_URL   = 'https://sso.carrier.com/oauth2/default/v1/token';
our $CLIENT_ID = '0oa1ce7hwjuZbfOMB4x7';

my %MUTATION = (
    updateInfinityConfig =>
        'mutation updateInfinityConfig($input: InfinityConfigInput!)'
      . ' { updateInfinityConfig(input: $input) { etag } }',
    updateInfinityZoneActivity =>
        'mutation updateInfinityZoneActivity($input: InfinityZoneActivityInput!)'
      . ' { updateInfinityZoneActivity(input: $input) { etag } }',
    updateInfinityZoneConfig =>
        'mutation updateInfinityZoneConfig($input: InfinityZoneConfigInput!)'
      . ' { updateInfinityZoneConfig(input: $input) { etag } }',
);

my $LOGIN_Q =
    'mutation assistedLogin($input: AssistedLoginInput!) {'
  . ' assistedLogin(input: $input) { success status errorMessage'
  . ' data { token_type expires_in access_token scope refresh_token } } }';

sub new {
    my ($class, %args) = @_;

    my $store  = $args{store}  or die "Carrier: store required";
    my $config = $args{config} or die "Carrier: config required";

    return bless { enabled => 0 }, $class
        unless $config->{carrier_user} and $config->{carrier_pass};

    my $ua = $args{ua} || Mojo::UserAgent->new;
    $ua->connect_timeout(15)->inactivity_timeout(30);

    my $self = bless {
        enabled     => 1,
        store       => $store,
        config      => $config,
        log         => $args{log},
        ua          => $ua,
        # Queue state is deliberately in-memory: see _tick. Tokens are too,
        # so that no bearer token is ever written to a store key that
        # /*catchall would happily serve to anyone who can reach the box.
        dirty       => {},
        seq         => 0,
        inflight    => 0,
        last_change => 0,
        last_push   => 0,
        # `//` not `||`: 0 is a legitimate value meaning "no delay", and the
        # surrounding house style of `||` would silently turn it into the
        # default.
        push_delay  => $config->{carrier_push_delay}   // 5,
        min_interval=> $config->{carrier_min_interval} // 10,
        dryrun      => $config->{carrier_dryrun},
    }, $class;

    return $self;
}

sub enabled { shift->{enabled} }

sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{log};
    $self->{log}->$level($msg);
}

# Unwrap single-element arrays from the XML->JSON mapping
sub _v {
    my $val = shift;
    return '' unless defined $val;
    $val = $val->[0] if ref($val) eq 'ARRAY' && @$val == 1;
    return '' if ref($val) eq 'HASH' && !keys %$val;
    return "$val";
}

sub _num { my $v = _v(shift); return $v eq '' ? undef : 0 + $v }

# --------------------------------------------------------------- dirty tracking

# Called from Infinitude.pm's domain methods AFTER the local write. Never
# issues a request itself: a slider drag calls set_zone_setpoint many times a
# second, and concurrent non-blocking writes can land out of order, which would
# leave Carrier holding an intermediate value and echo it back over the newer
# local one.
sub mark_dirty {
    my ($self, $key) = @_;
    return unless $self->{enabled};
    $self->{dirty}{$key} = 1;
    $self->{seq}++;
    $self->{last_change} = time;
    return;
}

# The web UI does not use the domain methods: every edit is a whole-document
# save through POST /systems/infinitude. Reduce a document to the fields we can
# actually push, so a save can be diffed into the same dirty keys mark_dirty
# would have set.
sub _summary {
    my ($self, $xml) = @_;
    my %s;
    my $cfg = $xml->system->config or return \%s;
    $s{mode} = _v($cfg->mode);

    my $zones = $cfg->zones->zone;
    $zones = [$zones] unless ref($zones) eq 'ARRAY';
    for my $z (@$zones) {
        my $id = _v($z->id);
        next if $id eq '';
        $s{"zone_${id}_hold"} =
            join '|', map { _v($z->$_) } qw/hold holdActivity otmr/;

        my $acts = $z->activities->activity;
        $acts = [$acts] unless ref($acts) eq 'ARRAY';
        for my $act (@$acts) {
            next unless _v($act->id) eq 'manual';
            $s{"zone_${id}_setpoint"} = _v($act->htsp) . '|' . _v($act->clsp);
            $s{"zone_${id}_fan"}      = _v($act->fan);
        }
    }
    return \%s;
}

sub mark_from_diff {
    my ($self, $before, $after) = @_;
    return unless $self->{enabled};
    return unless defined $after and length $after;

    my $b = try { $self->_summary(XML::Simple::Minded->new($before // '')) };
    my $a = try { $self->_summary(XML::Simple::Minded->new($after)) };
    unless ($a) {
        $self->_log(error => 'Carrier cloud: could not diff saved document');
        return;
    }
    $b ||= {};

    my @changed;
    for my $key (sort keys %$a) {
        next if defined $b->{$key} and $b->{$key} eq $a->{$key};
        push @changed, $key;
        $self->mark_dirty($key);
    }
    $self->_log(info => 'Carrier cloud: document save changed ' . join(', ', @changed))
        if @changed;
    return scalar @changed;
}

sub start {
    my $self = shift;
    return unless $self->{enabled};
    $self->{timer} ||= Mojo::IOLoop->recurring(2 => sub { $self->tick });
    $self->_log(info => 'Carrier cloud push enabled for '
        . ($self->_serial // 'unknown serial')
        . ($self->{dryrun} ? ' (DRY RUN)' : ''));
    return $self;
}

# ------------------------------------------------------------------- the queue

sub tick {
    my $self = shift;
    return unless $self->{enabled};
    return if $self->{inflight};
    return unless %{ $self->{dirty} };

    my $now = time;
    # Quiet period: coalesce a burst of edits into one write.
    return if $now - $self->{last_change} < $self->{push_delay};
    # Floor between pushes so a runaway automation can't hammer Carrier.
    if ($now - $self->{last_push} < $self->{min_interval}) {
        $self->_log(debug => 'Carrier cloud: push deferred by min_interval');
        return;
    }

    my $seq  = $self->{seq};
    my @keys = sort keys %{ $self->{dirty} };
    $self->{dirty}     = {};
    $self->{inflight}  = 1;
    $self->{last_push} = $now;

    my @muts = $self->_mutations_for(@keys);
    unless (@muts) {
        $self->{inflight} = 0;
        return;
    }

    $self->_log(info => 'Carrier cloud: pushing ' . scalar(@muts)
        . ' mutation(s) for: ' . join(', ', @keys));

    # Chained, never parallel. Ordering is then guaranteed by construction.
    # Note `for my $m`: a statement-modifier `for` would alias the global $_,
    # which has long since moved on by the time a promise actually resolves.
    my $p = Mojo::Promise->resolve;
    for my $m (@muts) {
        $p = $p->then(sub { $self->_mutate_p(@$m) });
    }

    $p->then(sub {
        $self->_log(info => 'Carrier cloud: push complete');
        $self->_record_pushed_hash;
    })->catch(sub {
        my $err = shift // 'unknown error';
        chomp $err;
        # Local state is already correct; this only means Carrier is behind.
        $self->_log(error => "Carrier cloud push failed: $err");
        $self->{dirty}{$_} = 1 for @keys;
    })->finally(sub {
        $self->{inflight} = 0;
        if ($self->{seq} != $seq) {
            # Something changed while we were in flight. Re-mark so the next
            # tick re-reads current values and sends the newer state.
            $self->{dirty}{$_} = 1 for @keys;
            $self->_log(info => 'Carrier cloud: changed during push, re-sending');
        }
    });

    return;
}

# ------------------------------------------------------------------- mutations

sub _serial {
    my $self = shift;
    return $self->{serial} if $self->{serial};
    my $s = $self->{config}{carrier_serial};
    unless ($s) {
        for my $k ($self->{store}->get_keys) {
            if ($k =~ /^req-systems-([^-]+)-status\.txt$/) { $s = $1; last }
        }
    }
    return $self->{serial} = $s;
}

sub _manual_activity {
    my ($self, $xml, $zone_id) = @_;
    my $zone = $xml->system->config->zones->zone->[$zone_id - 1] or return undef;
    for my $activity (@{ $zone->activities->activity }) {
        return $activity if $activity->id eq 'manual';
    }
    return undef;
}

# Values are read from systems.xml HERE, at push time, never captured when the
# setter ran. That makes a coalesced or retried push idempotent and
# self-correcting: it always carries current truth.
sub _mutations_for {
    my ($self, @keys) = @_;

    my $serial = $self->_serial;
    unless ($serial) {
        $self->_log(error => 'Carrier cloud: no serial configured or detected');
        return ();
    }

    my $xml = try { XML::Simple::Minded->new($self->{store}->get('systems.xml')) };
    unless ($xml) {
        $self->_log(error => 'Carrier cloud: systems.xml unreadable');
        return ();
    }

    my @out;
    for my $key (@keys) {
        if ($key eq 'mode') {
            my $mode = _v($xml->system->config->mode);
            push @out, [ updateInfinityConfig => { serial => $serial, mode => $mode } ]
                if $mode ne '';
        }
        elsif (my ($z, $what) = $key =~ /^zone_(\d+)_(setpoint|fan)$/) {
            my $a = $self->_manual_activity($xml, $z);
            unless ($a) {
                $self->_log(error => "Carrier cloud: no manual activity for zone $z");
                next;
            }
            my %input = (serial => $serial, zoneId => "$z", activityType => 'manual');
            if ($what eq 'setpoint') {
                $input{htsp} = _num($a->htsp);
                $input{clsp} = _num($a->clsp);
                next unless defined $input{htsp} or defined $input{clsp};
            }
            else {
                my $fan = _v($a->fan);
                next if $fan eq '';
                $input{fan} = $fan;
            }
            push @out, [ updateInfinityZoneActivity => \%input ];
        }
        elsif (my ($hz) = $key =~ /^zone_(\d+)_hold$/) {
            my $zone = $xml->system->config->zones->zone->[$hz - 1] or next;
            push @out, [ updateInfinityZoneConfig => {
                serial       => $serial,
                zoneId       => "$hz",
                hold         => _v($zone->hold),
                holdActivity => _v($zone->holdActivity),
                otmr         => (_v($zone->otmr) eq '' ? undef : _v($zone->otmr)),
            } ];
        }
        else {
            # set_zone_hold accepts 'wholeHouse', which has no Carrier zoneId.
            $self->_log(info => "Carrier cloud: no mutation for '$key', skipping");
        }
    }
    return @out;
}

sub _mutate_p {
    my ($self, $name, $input) = @_;

    if ($self->{dryrun}) {
        $self->_log(info => "Carrier cloud DRYRUN $name " . encode_json($input));
        return Mojo::Promise->resolve;
    }

    my $query = $MUTATION{$name} or return Mojo::Promise->reject("unknown mutation $name");

    return $self->_token_p->then(sub {
        my $auth = shift;
        $self->{ua}->post_p($GQL_URL =>
            { Authorization => $auth, 'Content-Type' => 'application/json' } =>
            json => { query => $query, variables => { input => $input } });
    })->then(sub {
        my $tx   = shift;
        my $res  = $tx->res;
        my $json = $res->json;
        die "HTTP " . ($res->code // 0) . "\n" unless $res->is_success;
        die 'GraphQL: ' . encode_json($json->{errors}) . "\n"
            if $json && $json->{errors};
        my $etag = eval { $json->{data}{$name}{etag} };
        $self->_log(info => "Carrier cloud $name ok" . ($etag ? " etag=$etag" : ''));
        return 1;
    });
}

# ----------------------------------------------------------------------- token

# Tokens live in memory only. Persisting them would mean writing a bearer
# token to a CHI key that /*catchall serves unauthenticated; a fresh login on
# restart costs one request and avoids that entirely.
sub _token_p {
    my $self = shift;

    return Mojo::Promise->resolve($self->{token})
        if $self->{token} and time < ($self->{token_exp} // 0) - 60;

    if (my $refresh = $self->{refresh_token}) {
        return $self->_refresh_p($refresh)->catch(sub {
            $self->_log(info => 'Carrier cloud: refresh failed, doing full login');
            $self->_login_p;
        });
    }
    return $self->_login_p;
}

sub _store_token {
    my ($self, $data) = @_;
    die "no access_token in response\n" unless $data && $data->{access_token};
    $self->{token}         = ($data->{token_type} // 'Bearer') . ' ' . $data->{access_token};
    $self->{token_exp}     = time + ($data->{expires_in} // 3600);
    $self->{refresh_token} = $data->{refresh_token} if $data->{refresh_token};
    return $self->{token};
}

sub _login_p {
    my $self = shift;
    my $c = $self->{config};
    $self->_log(info => 'Carrier cloud: logging in');
    return $self->{ua}->post_p($LOGIN_URL =>
        { 'Content-Type' => 'application/json' } =>
        json => {
            query     => $LOGIN_Q,
            variables => { input => {
                username => $c->{carrier_user},
                password => $c->{carrier_pass},
            } },
        })->then(sub {
            my $json = shift->res->json;
            die 'login: ' . encode_json($json->{errors}) . "\n"
                if $json && $json->{errors};
            my $login = $json && $json->{data} && $json->{data}{assistedLogin}
                or die "login: unexpected response shape\n";
            die 'login: ' . ($login->{errorMessage} // 'failed') . "\n"
                unless $login->{data};
            return $self->_store_token($login->{data});
        });
}

sub _refresh_p {
    my ($self, $refresh) = @_;
    return $self->{ua}->post_p($SSO_URL => form => {
        client_id     => $CLIENT_ID,
        grant_type    => 'refresh_token',
        refresh_token => $refresh,
        scope         => 'offline_access',
    })->then(sub {
        my $res = shift->res;
        die "refresh: HTTP " . ($res->code // 0) . "\n" unless $res->is_success;
        return $self->_store_token($res->json);
    });
}

# ------------------------------------------------------------- echo detection

# Carrier echoes our own writes back down via the carrier_changes path. Record
# what we last pushed so that echo can be recognised rather than treated as a
# foreign change. Numbers are normalised because Carrier may return 78 as
# "78.0" - comparing raw strings would make every push look foreign.
sub config_digest {
    my ($class, $xml_string) = @_;
    return '' unless defined $xml_string and length $xml_string;
    my $canon = try { XML::Simple::Minded->new($xml_string) . '' };
    return '' unless defined $canon and length $canon;
    $canon =~ s{>(\s*-?\d+)\.0+(\s*)<}{>$1$2<}g;    # 78.0 -> 78
    return md5_hex($canon);
}

sub _record_pushed_hash {
    my $self = shift;
    my $cfg = try {
        my $xml = XML::Simple::Minded->new($self->{store}->get('systems.xml'));
        XML::Simple::Minded->new({ config => $xml->system->config }) . '';
    };
    return unless defined $cfg and length $cfg;
    $self->{store}->set(carrier_pushed_hash => __PACKAGE__->config_digest($cfg));
    return;
}

# True while local intent has not yet reached Carrier. The pull path must not
# overwrite systems.xml in that window: Carrier is by definition answering with
# pre-change state, and persisting it would silently discard the user's input.
sub has_pending {
    my $self = shift;
    return 0 unless $self->{enabled};
    return ($self->{inflight} or %{ $self->{dirty} }) ? 1 : 0;
}

1;
