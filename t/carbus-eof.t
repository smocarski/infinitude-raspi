#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 'lib';
use Socket qw/AF_UNIX SOCK_STREAM PF_UNSPEC/;
use IO::Socket;
use CarBus;

# A TCP RS485 bridge that closes its end must be noticed, so the app can
# reopen it instead of reading EOF forever.
my ($ours, $peer) = IO::Socket->socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
my $bus = CarBus->new($ours);

ok(!$bus->eof, 'open connection is not at EOF');
is($bus->get_frame, undef, 'no data, no frame');
ok(!$bus->eof, 'still not at EOF with nothing to read');

close $peer;
$bus->get_frame;
ok($bus->eof, 'EOF flagged after the peer closes');

done_testing();
