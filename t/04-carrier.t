use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CHI;
use File::Temp qw/tempdir/;
use Mojo::IOLoop;
use Mojo::Promise;
use Path::Tiny;

BEGIN { use_ok('Infinitude::Carrier') }

# Hermetic: uses the committed fixture, never the live state/ directory.
my $FIXTURE = path("$FindBin::Bin/systems17.raw")->slurp;

# --- Mocks --------------------------------------------------------------

package MockUA {
    sub new { bless { posts => [], fail => 0 }, shift }
    sub connect_timeout    { shift }
    sub inactivity_timeout { shift }
    sub posts { shift->{posts} }
    sub mutations {
        my $s = shift;
        return [ grep { ($_->{query} // '') =~ /mutation updateInfinity/ } @{ $s->{posts} } ];
    }
    sub post_p {
        my ($self, $url, @rest) = @_;
        my $body = ref($rest[-1]) eq 'HASH' ? $rest[-1] : {};
        push @{ $self->{posts} }, { url => $url, %$body };
        return Mojo::Promise->new->reject("mock failure\n") if $self->{fail};
        my $name = ($body->{query} // '') =~ /mutation (\w+)/ ? $1 : 'assistedLogin';
        return Mojo::Promise->new->resolve(MockTx->new(MockRes->new($name)));
    }
}
package MockRes {
    sub new { bless { n => $_[1] }, $_[0] }
    sub is_success { 1 }
    sub code       { 200 }
    sub json {
        my $s = shift;
        return { data => { assistedLogin => { success => 1, data => {
            token_type => 'Bearer', access_token => 'AAA',
            expires_in => 3600,     refresh_token => 'RRR' } } } }
            if $s->{n} eq 'assistedLogin';
        return { data => { $s->{n} => { etag => 'etag-' . $s->{n} } } };
    }
}
package MockTx {
    sub new { bless { r => $_[1] }, $_[0] }
    sub res { shift->{r} }
}
package main;

sub make {
    my %extra = @_;
    my $dir   = tempdir(CLEANUP => 1);
    my $store = CHI->new(driver => 'File', root_dir => $dir, depth => 0,
                         max_key_length => 256, namespace => '');
    $store->set('systems.xml', $FIXTURE);
    my $ua = MockUA->new;
    my $c  = Infinitude::Carrier->new(
        store  => $store,
        ua     => $ua,
        config => {
            carrier_user   => 'u',
            carrier_pass   => 'p',
            carrier_serial => 'TESTSERIAL',
            # 0 is meaningful here; the module uses // so it survives
            carrier_push_delay   => 0,
            carrier_min_interval => 0,
            %extra,
        },
    );
    return ($c, $ua, $store);
}

# Let queued promise callbacks run. Nothing does real I/O.
sub settle { Mojo::IOLoop->one_tick for 1 .. 60 }

subtest 'disabled without credentials' => sub {
    my $c = Infinitude::Carrier->new(store => 1, config => {});
    ok(!$c->enabled, 'not enabled');
    $c->mark_dirty('mode');
    ok(!$c->has_pending, 'mark_dirty is a no-op when disabled');
};

subtest 'mutations built from systems.xml' => sub {
    my ($c) = make();
    my @m = $c->_mutations_for(qw/mode zone_1_setpoint zone_1_fan zone_1_hold/);
    is(scalar @m, 4, 'four mutations');

    my ($cfg) = grep { $_->[0] eq 'updateInfinityConfig' } @m;
    is($cfg->[1]{mode},   'auto',       'mode read from the document');
    is($cfg->[1]{serial}, 'TESTSERIAL', 'serial applied');

    my ($sp) = grep { defined $_->[1]{htsp} } @m;
    is($sp->[0], 'updateInfinityZoneActivity', 'setpoint uses zone activity');
    is($sp->[1]{activityType}, 'manual', 'activityType is manual');
    is($sp->[1]{zoneId}, '1', 'zoneId is the 1-based index');
    like($sp->[1]{htsp}, qr/^\d+$/, 'htsp is numeric');
    like($sp->[1]{clsp}, qr/^\d+$/, 'clsp is numeric');

    my ($hold) = grep { $_->[0] eq 'updateInfinityZoneConfig' } @m;
    is($hold->[1]{hold}, 'off', 'hold read from the zone');
};

subtest 'coalescing: a burst produces one push' => sub {
    my ($c, $ua) = make();
    $c->mark_dirty('zone_1_setpoint') for 1 .. 10;
    is(scalar @{ $ua->posts }, 0, 'nothing sent before the tick');
    $c->tick;
    settle();
    is(scalar @{ $ua->mutations }, 1, 'ten marks collapsed into one mutation');
};

subtest 'single-flight: nothing issued while in flight' => sub {
    my ($c, $ua) = make();
    $c->{inflight} = 1;
    $c->mark_dirty('mode');
    $c->tick;
    is(scalar @{ $ua->posts }, 0, 'tick is a no-op while a push is outstanding');
    ok($c->has_pending, 'work is still queued');
};

subtest 'a change during flight is re-pushed' => sub {
    my ($c, $ua) = make();
    $c->mark_dirty('mode');
    my $seq = $c->{seq};
    $c->tick;
    $c->mark_dirty('mode');    # lands mid-flight
    settle();
    isnt($c->{seq}, $seq, 'sequence advanced');
    ok($c->has_pending, 'field re-marked so the newer value gets sent');
    is($c->{inflight}, 0, 'inflight cleared');
};

subtest 'cloud failure never throws and keeps the work queued' => sub {
    my ($c, $ua) = make();
    $ua->{fail} = 1;
    $c->mark_dirty('mode');
    my $ok = eval { $c->tick; settle(); 1 };
    ok($ok, 'tick did not propagate the failure') or diag($@);
    ok($c->has_pending, 'still queued for retry');
    is($c->{inflight}, 0, 'inflight cleared after failure');
};

subtest 'dryrun sends nothing' => sub {
    my ($c, $ua) = make(carrier_dryrun => 1);
    $c->mark_dirty('mode');
    $c->tick;
    settle();
    is(scalar @{ $ua->posts }, 0, 'no requests issued in dryrun');
};

subtest 'wholeHouse hold is skipped rather than fatal' => sub {
    my ($c) = make();
    my @m = $c->_mutations_for('zone_wholeHouse_hold');
    is(scalar @m, 0, 'no mutation, no exception');
};

subtest 'whole-document save is diffed into dirty keys' => sub {
    # This is the path the web UI actually uses: POST /systems/infinitude
    # saves the entire document rather than calling the domain methods.
    my ($c) = make();

    is($c->mark_from_diff($FIXTURE, $FIXTURE), 0, 'identical save marks nothing');
    ok(!$c->has_pending, 'nothing queued for an unchanged save');

    my $mode_changed = $FIXTURE;
    $mode_changed =~ s{<config><mode>auto</mode>}{<config><mode>cool</mode>};
    isnt($mode_changed, $FIXTURE, 'fixture was actually modified');
    ok($c->mark_from_diff($FIXTURE, $mode_changed), 'mode change detected');
    ok($c->has_pending, 'queued for push');

    my ($c2) = make();
    my $sp_changed = $FIXTURE;
    $sp_changed =~ s{(<activity id="manual"><htsp>)([\d.]+)}{$1 . ($2 + 3)}se;
    isnt($sp_changed, $FIXTURE, 'a manual setpoint was modified');
    ok($c2->mark_from_diff($FIXTURE, $sp_changed), 'setpoint change detected');
    ok((grep { /_setpoint$/ } keys %{ $c2->{dirty} }), 'marked a zone setpoint key')
        or diag('dirty: ' . join(',', sort keys %{ $c2->{dirty} }));

    my ($c3) = make();
    is($c3->mark_from_diff($FIXTURE, 'not xml at all <'), undef,
        'a malformed save is ignored rather than fatal');
};

subtest 'config_digest normalises Carrier float formatting' => sub {
    my $a = Infinitude::Carrier->config_digest('<config><clsp>78.0</clsp></config>');
    my $b = Infinitude::Carrier->config_digest('<config><clsp>78</clsp></config>');
    my $d = Infinitude::Carrier->config_digest('<config><clsp>79</clsp></config>');
    ok($a, 'digest produced');
    is($a, $b, '78.0 and 78 hash identically');
    isnt($a, $d, 'a genuine difference still differs');
    is(Infinitude::Carrier->config_digest(undef), '', 'undef is tolerated');
};

done_testing();
