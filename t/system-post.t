use Test::More;
use Test::Mojo;

# Include application
use FindBin;
use lib "$FindBin::Bin/../lib";
use CHI;

require "$FindBin::Bin/../infinitude";
$main::config = { app_secret => 'testing', pass_reqs=>0 };
$main::store = CHI->new(driver=>'Memory', global=>1);

use XML::Simple::Minded;

# Allow 302 redirect responses
my $t = Test::Mojo->new;
$t->ua->max_redirects(1);

$t->get_ok('/')->status_is(200);
$t->get_ok('/Alive')->status_is(200);
$t->content_is('alive');

my $systems17_raw = Mojo::Asset::File->new(path => "$FindBin::Bin/systems17.raw");

# The Host header has to match before_dispatch's (bryant|carrier|ioncomfort|
# infinitude) regex, otherwise the hook never runs, the data param is never
# parsed, and the POST below silently hits the no-op branch of
# post '/systems/:id'. pass_reqs=>0 keeps the hook from relaying to Carrier.
$t->post_ok('/systems/systems17test'
	=> {Accept=>'*/*', Host=>'infinitude'}
	=> form => {data=>$systems17_raw->slurp});

$t->get_ok('/systems.xml')->status_is(200);

my $xml_string = $t->tx->res->body;
my $xml = XML::Simple::Minded->new($xml_string);
isa_ok($xml,'XML::Simple::Minded');

# Assert the POST actually landed rather than just that we got parseable XML
ok($xml_string =~ /<system\b/, 'systems.xml holds a system document');
is($xml->system->config->mode.'', 'auto', 'config survived the round trip');
ok(defined $main::store->get('systems17test.xml'), 'store_key artifacts written');

# A routine thermostat status poll is per-request noise and must not log at
# info. Before this was fixed every ~32s poll wrote three info lines.
{
    my @msgs;
    $t->app->log->level('debug');
    my $cb = $t->app->log->on(message => sub {
        my ($log, $level, @lines) = @_;
        push @msgs, [$level, join ' ', @lines];
    });
    $t->post_ok('/systems/systems17test/status' => {Host=>'infinitude'})->status_is(200);
    $t->app->log->unsubscribe(message => $cb);

    my @info = grep { $_->[0] =~ /^(info|warn|error|fatal)$/ } @msgs;
    is(scalar @info, 0, 'routine status poll logs nothing above debug')
        or diag(join "\n", map { "$_->[0]: $_->[1]" } @info);
    ok((grep { $_->[0] eq 'debug' } @msgs), 'but still logs at debug');
}

done_testing();
