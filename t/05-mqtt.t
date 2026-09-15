use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;
use CHI;

BEGIN { use_ok('Infinitude::MQTT') }

# --- Mocks --------------------------------------------------------------

package MockClient {
    sub new { bless { ticks => [], retained => [], subs => {} }, shift }
    sub last_will { }
    sub script { my ($s, @t) = @_; $s->{ticks} = [@t] }
    sub tick { my $s = shift; @{ $s->{ticks} } ? shift @{ $s->{ticks} } : 1 }
    sub retain { my ($s, $t, $m) = @_; push @{ $s->{retained} }, [$t, $m] }
    sub subscribe { my ($s, %kv) = @_; @{ $s->{subs} }{ keys %kv } = values %kv }
    sub onlines { scalar grep { $_->[0] eq 'infinitude/status' && $_->[1] eq 'online' } @{ shift->{retained} } }
    sub reset { shift->{retained} = [] }
}

package MockLog {
    sub new { bless { msgs => [] }, shift }
    for my $level (qw/debug info warn error/) {
        no strict 'refs';
        *$level = sub { push @{ $_[0]{msgs} }, [$level, $_[1]] };
    }
    sub count { my ($s, $level, $re) = @_;
        scalar grep { $_->[0] eq $level && (!$re || $_->[1] =~ $re) } @{ $s->{msgs} } }
    sub reset { shift->{msgs} = [] }
}

package main;

sub make {
    my $store  = CHI->new(driver => 'Memory', datastore => {});
    my $client = MockClient->new;
    my $log    = MockLog->new;
    my $m = Infinitude::MQTT->new(
        store  => $store,
        client => $client,
        log    => $log,
        config => { mqtt_broker => 'broker.test:1883' },
    );
    return ($m, $client, $log, $store);
}

subtest 'disabled without a broker' => sub {
    my $m = Infinitude::MQTT->new(store => 1, config => {});
    ok(!$m->enabled, 'not enabled');
    ok(!$m->tick, 'tick is a no-op');
};

subtest 'announce asserts availability even with no status.json' => sub {
    # publish_discovery returns early without status.json; availability must
    # not depend on it.
    my ($m, $client) = make();
    $m->announce;
    is($client->onlines, 1, "infinitude/status 'online' retained");
};

subtest 'up -> down -> up: one warning, one recovery, re-announce' => sub {
    my ($m, $client, $log) = make();
    $client->script(1, 0, 1);

    $m->tick;
    is($log->count(info => qr/connected to broker\.test/), 1, 'initial connect logged');
    ok($m->connected, 'connected');

    $client->reset;
    $m->tick;
    is($log->count(warn => qr/connection to broker\.test:1883 lost/), 1, 'drop logged once');
    ok(!$m->connected, 'disconnected');

    $m->tick;
    is($log->count(info => qr/reconnected to broker\.test:1883 after \d+s/), 1, 'recovery logged');
    is($client->onlines, 1, "re-announced 'online' after reconnect");
    ok($m->connected, 'connected again');
};

subtest 'while down, warnings are rate-limited' => sub {
    my ($m, $client, $log) = make();
    $client->script((0) x 50);

    $m->tick for 1 .. 50;
    is($log->count('warn'), 1, 'fifty failed ticks inside 5 minutes warn once');

    # Pretend the last warning was over 5 minutes ago.
    $m->{last_down_warn} -= 301;
    $m->{down_since}     -= 301;
    $client->script(0);
    $m->tick;
    is($log->count(warn => qr/still unreachable after 5m/), 1, 'periodic still-down warning');
};

subtest 'Home Assistant birth message re-announces' => sub {
    my ($m, $client, $log) = make();
    $m->subscribe_commands;

    my $cb = $client->{subs}{'homeassistant/status'};
    ok($cb, 'subscribed to homeassistant/status');

    $cb->('homeassistant/status', 'offline');
    is($client->onlines, 0, "'offline' birth payload ignored");

    $cb->('homeassistant/status', 'online');
    is($client->onlines, 1, "'online' birth payload re-announces");
    is($log->count(info => qr/Home Assistant came online/), 1, 'logged');
};

subtest 'assert_online only publishes availability' => sub {
    my ($m, $client) = make();
    $m->assert_online;
    is_deeply($client->{retained}, [['infinitude/status', 'online']], 'single retained message');
};

done_testing();
