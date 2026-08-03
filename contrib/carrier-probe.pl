#!/usr/bin/env perl
#
# Phase 1 probe: prove Carrier's user-authenticated cloud API works with this
# account before writing any Infinitude integration.
#
# Run inside the infinitude container (it already has Mojolicious + TLS).
# Pass credentials via the environment so they stay out of shell history:
#
#   export CARRIER_USER='you@example.com'
#   read -rs -p 'Carrier password: ' CARRIER_PASS; echo; export CARRIER_PASS
#
#   docker exec -e CARRIER_USER -e CARRIER_PASS infinitude \
#       perl /infinitude/contrib/carrier-probe.pl
#
#   docker exec -e CARRIER_USER -e CARRIER_PASS infinitude \
#       perl /infinitude/contrib/carrier-probe.pl \
#       --serial 2015W001500 --zone 1 --clsp 78 --htsp 68 --write
#
# Without --write it only logs in and reports. Nothing is sent to Carrier that
# changes state unless --write is given.
#
# Diagnostic only - not used by the running application.
#
use strict;
use warnings;
use feature ':5.10';

use Mojo::UserAgent;
use Mojo::JSON qw/encode_json decode_json/;

my %o = (zone => 1, activity => 'manual');
while (@ARGV) {
    my $a = shift @ARGV;
    if    ($a eq '--write')   { $o{write} = 1 }
    elsif ($a =~ /^--(\w+)$/) { $o{$1} = shift @ARGV }
    else { die "unknown arg: $a\n" }
}

# Prefer the environment so the password never lands in shell history or ps
$o{user}   //= $ENV{CARRIER_USER};
$o{pass}   //= $ENV{CARRIER_PASS};
$o{serial} //= $ENV{CARRIER_SERIAL};

die "need --user/--pass (or CARRIER_USER/CARRIER_PASS in the environment)\n"
    unless $o{user} and $o{pass};

my $LOGIN_URL = 'https://dataservice.infinity.iot.carrier.com/graphql-no-auth';
my $GQL_URL   = 'https://dataservice.infinity.iot.carrier.com/graphql';

my $ua = Mojo::UserAgent->new;
$ua->connect_timeout(15)->inactivity_timeout(30);

sub gql {
    my ($url, $query, $vars, $auth) = @_;
    my %headers = ('Content-Type' => 'application/json');
    $headers{Authorization} = $auth if $auth;
    my $tx = $ua->post($url => \%headers
        => json => { query => $query, variables => $vars });
    my $res = $tx->res;
    return ($res->code // 0, $res->json, $res->body // '');
}

# ---------------------------------------------------------------- login
say "==> logging in as $o{user}";

my $LOGIN_Q = <<'GQL';
mutation assistedLogin($input: AssistedLoginInput!) {
  assistedLogin(input: $input) {
    success
    status
    errorMessage
    data { token_type expires_in access_token scope refresh_token }
  }
}
GQL

my ($code, $json, $raw) = gql($LOGIN_URL, $LOGIN_Q,
    { input => { username => $o{user}, password => $o{pass} } });

say "    HTTP $code";
unless ($json) {
    say "    no JSON in response. First 400 bytes:";
    say "    ", substr($raw, 0, 400);
    exit 1;
}
if (my $errs = $json->{errors}) {
    say "    GraphQL errors: ", encode_json($errs);
    exit 1;
}

my $login = $json->{data}{assistedLogin} or do {
    say "    unexpected shape: ", substr(encode_json($json), 0, 400);
    exit 1;
};
say "    success=", ($login->{success} // '?'), " status=", ($login->{status} // '?');
say "    errorMessage=", $login->{errorMessage} if $login->{errorMessage};

my $tok = $login->{data} or do { say "    no token returned"; exit 1 };
my $auth = "$tok->{token_type} $tok->{access_token}";
say "    token_type=$tok->{token_type} expires_in=$tok->{expires_in} scope=",
    ($tok->{scope} // '');
say "    access_token=", substr($tok->{access_token}, 0, 12), "...(",
    length($tok->{access_token}), " chars)";
say "    refresh_token=", ($tok->{refresh_token} ? 'present' : 'ABSENT');
say "==> LOGIN OK";

unless ($o{write}) {
    say "";
    say "Login works. Re-run with --serial S --zone N --clsp X --htsp Y --write";
    say "to attempt one setpoint write.";
    exit 0;
}

# ---------------------------------------------------------------- write
die "--write needs --serial, --clsp and --htsp\n"
    unless $o{serial} and defined $o{clsp} and defined $o{htsp};

my $SET_Q = <<'GQL';
mutation updateInfinityZoneActivity($input: InfinityZoneActivityInput!) {
  updateInfinityZoneActivity(input: $input) { etag }
}
GQL

my $input = {
    serial       => $o{serial},
    zoneId       => "$o{zone}",
    activityType => $o{activity},
    clsp         => $o{clsp},
    htsp         => $o{htsp},
};

say "";
say "==> updateInfinityZoneActivity";
say "    input: ", encode_json($input);

($code, $json, $raw) = gql($GQL_URL, $SET_Q, { input => $input }, $auth);
say "    HTTP $code";

if (!$json) {
    say "    no JSON. First 400 bytes:";
    say "    ", substr($raw, 0, 400);
    exit 1;
}
if (my $errs = $json->{errors}) {
    say "    GraphQL errors:";
    say "      ", encode_json($_) for @$errs;
    say "";
    say "    (an error naming zoneId or activityType tells us the expected";
    say "     format - that is useful output, not a failure of the approach)";
    exit 1;
}

my $etag = $json->{data}{updateInfinityZoneActivity}{etag};
if ($etag) {
    say "    etag=$etag";
    say "==> WRITE ACCEPTED";
    say "";
    say "Now check the Carrier app for zone $o{zone}: clsp=$o{clsp} htsp=$o{htsp}";
    say "Then, once Infinitude next polls Carrier (up to PASS_REQS seconds),";
    say "compare what Carrier echoes back against what was just sent:";
    say "";
    say "  docker exec infinitude perl -e 'open F,\"<:raw\",\"/infinitude/state/systems-$o{serial}-config+2exml.dat\"; local \$/; \$_=<F>; s/^.*?(?=<)//s; print \"\$1\\n\" while /<(?:cl|ht)sp>[^<]*</g'";
    say "";
    say "If Carrier returns 78 as \"78.0\" or clamps it, the echo-detection hash";
    say "in Phase 5 needs to normalise before comparing.";
} else {
    say "    no etag in response: ", substr(encode_json($json), 0, 400);
    exit 1;
}
