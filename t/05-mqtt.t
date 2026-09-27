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
    sub _drop_connection { shift->{dropped}++ }
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

subtest 'silent half-open connection is detected and reconnected' => sub {
    my ($m, $client, $log) = make();
    $m->subscribe_commands;
    my $echo = $client->{subs}{'infinitude/status'};
    ok($echo, 'subscribed to our own status topic');

    $client->script(1, 1);
    $m->tick;
    $m->tick;
    ok(!$client->{dropped}, 'fresh connection gets a grace period');

    # An echo inside the window keeps the connection.
    $m->{up_since} -= 1000;
    $m->{last_rx}  -= 100;
    $echo->('infinitude/status', 'online');
    $client->script(1);
    $m->tick;
    ok(!$client->{dropped}, 'recent echo: no forced reconnect');

    # Nothing back from the broker for longer than $STALE_AFTER.
    $m->{last_rx} -= $Infinitude::MQTT::STALE_AFTER + 1;
    $client->script(1);
    $m->tick;
    is($client->{dropped}, 1, 'forced reconnect');
    is($log->count(warn => qr/no traffic from broker\.test:1883 for \d+s, forcing reconnect/), 1, 'logged');
    is($log->count(warn => qr/connection to broker\.test:1883 lost/), 1, 'treated as a drop');
    ok(!$m->connected, 'marked down');

    $client->reset;
    $client->script(1, 1);
    $m->tick;
    is($client->onlines, 1, 're-announced on recovery');
    $m->tick;
    is($client->{dropped}, 1, 'new connection is not immediately dropped again');
};

subtest "our own stale 'offline' last will is corrected" => sub {
    my ($m, $client) = make();
    $m->subscribe_commands;
    my $echo = $client->{subs}{'infinitude/status'};

    $echo->('infinitude/status', 'offline');
    is($client->onlines, 0, 'not re-asserted before we are connected');

    $client->script(1);
    $m->tick;
    $echo->('infinitude/status', 'offline');
    is($client->onlines, 1, "'online' re-asserted");
};

subtest 'socket hardening' => sub {
    use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC SOL_SOCKET SO_KEEPALIVE/;
    use IO::Socket::IP;

    ok(!Infinitude::MQTT::_harden_socket(undef), 'no socket: no-op');
    ok(!Infinitude::MQTT::_harden_socket({}), 'not a handle: no-op');

    my $listen = IO::Socket::IP->new(Listen => 1, LocalHost => '127.0.0.1', LocalPort => 0)
        or plan skip_all => 'cannot listen on loopback';
    my $sock = IO::Socket::IP->new(PeerHost => '127.0.0.1', PeerPort => $listen->sockport)
        or plan skip_all => 'cannot connect on loopback';
    ok(Infinitude::MQTT::_harden_socket($sock), 'hardened');
    ok(unpack('i', getsockopt($sock, SOL_SOCKET, SO_KEEPALIVE)), 'SO_KEEPALIVE set');

    # tick hardens each new socket the client opens, once.
    my ($m, $client) = make();
    $client->{socket} = $sock;
    setsockopt($sock, SOL_SOCKET, SO_KEEPALIVE, 0);
    $client->script(1);
    $m->tick;
    ok(unpack('i', getsockopt($sock, SOL_SOCKET, SO_KEEPALIVE)), 'tick hardened the client socket');
};

done_testing();
