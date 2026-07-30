#!/usr/bin/perl -w

use strict;
use warnings;

use Cwd 'abs_path';

use SReview::Db;
use SReview::Config::Common;

my $config = SReview::Config::Common::setup;

$config->set(secret => "foo",
	     outputdir => abs_path('t/outputdir'),
	     pubdir => abs_path('t/pubdir'),
	     preroll_template => abs_path('t/testvids/just-title.svg'),
	     postroll_template => abs_path('t/testvids/just-title.svg'),
	     adminpw => "adminpw", adminuser => 'admin@example.com',
	     apology_template => abs_path('t/testvids/just-title.svg'));

if(exists($ENV{SREVIEWTEST_DB})) {
	$config->set(dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB});
}

use Test::More;
use Test::Mojo;
use Mojo::File qw/path/;

my $do_auth = 0;

SKIP: {
	skip("Need a database to play with", 1) unless (exists($ENV{SREVIEWTEST_DB}) or exists($ENV{SREVIEWTEST_INSTALLED}) or exists($ENV{AUTOPKGTEST_TMP}));

	SReview::Db::init(SReview::Config::Common::setup());
	SReview::Db::selfdestruct(code => 0, init => 0);

	my $script;
	my $b = '/api/v1';

	if(exists($ENV{SREVIEWTEST_INSTALLED}) or exists($ENV{AUTOPKGTEST_TMP})) {
		$script = "SReview::Web";
	} else {
		$script = path(__FILE__);
		$script = $script->dirname->child('..')->child('web')->child('sreview-web')->to_abs;
		symlink "../t", "web/t";
		chdir($script->dirname);
	}
	my $t = Test::Mojo->new($script);
	$t->get_ok("$b/speaker/search/Wouter" => { "X-SReview-Key" => "foobarbaz" })->status_is(401);
	$config->set(api_key => "foobarbaz");
	$t = Test::Mojo->new($script);

	my $admin_key = undef;

	$t->ua->on(start => sub {
		my ($ua, $tx) = @_;
		if(defined($admin_key)) {
			$tx->req->headers->add("X-SReview-Key" => $admin_key);
		} elsif($do_auth) {
			$tx->req->headers->add("X-SReview-Key" => "foobarbaz");
		}
	});

	# Invalid authentication key
	$t->get_ok("$b/event/1/talk/list" => { "X-SReview-Key" => "foobar" })->status_is(401);
	# Events
	$t->get_ok("$b/")->status_is(200)->json_is("/info/title" => "SReview API")->json_is("/info/version" => "1.0.0");
	$t->get_ok("$b/event/list")->status_is(200)->json_is(""=>[]);
	$t->post_ok("$b/event" => json => {name => 'Test event'})->status_is(401);
	$do_auth = 1;
	$t->post_ok("$b/event" => json => {name => 'Test event'})->status_is(200)->json_is('/name' => "Test event")->json_is('/inputdir' => undef)->json_is('/id' => 1);
	$do_auth = 0;
	$t->get_ok("$b/event/list")->status_is(200)->json_is('/0/name' => 'Test event')->json_is('/0/inputdir' => undef);
	$t->get_ok("$b/event/1")->status_is(200)->json_is('/name' => 'Test event');
	$t->patch_ok("$b/event/1" => json => {inputdir => "foo"})->status_is(401);
	# admin key
	$t->post_ok("/login_post" => form => { email => 'admin@example.com', pass => "adminpw"})->status_is(302)->header_is(Location => "/overview");
	foreach my $cookie(@{$t->tx->res->cookies}) {
		next unless ($cookie->name eq 'sreview_api_key');
		$admin_key = $cookie->value;
		last;
	}
	ok(defined($admin_key), "we have an admin key");
	$t->patch_ok("$b/event/1" => json => {inputdir => "foo"})->status_is(200)->json_is('/inputdir' => 'foo')->json_is('/name' => 'Test event');
	$t->post_ok("$b/event" => json => {name => 'bad event'})->status_is(200)->json_is('/id' => 2);
	$admin_key = undef;
	$t->reset_session;
	$t->delete_ok("$b/event/2")->status_is(401);
	$t->get_ok("$b/event/2")->status_is(200)->json_is('/id' => 2)->json_is('/name' => 'bad event');
	$do_auth = 1;
	$t->delete_ok("$b/event/2")->status_is(200);
	$t->get_ok("$b/event/2")->status_is(404);
	$t->delete_ok("$b/event/2")->status_is(404);

	# Rooms
	$t->get_ok("$b/room/list")->status_is(200)->json_is(""=>[]);
	$t->post_ok("$b/room" => json => {name => 'Test room'})->status_is(200)->json_is('/name' => 'Test room')->json_is('/id' => 1);
	$t->get_ok("$b/room/1")->status_is(200)->json_is('/name' => 'Test room')->json_is('/id' => 1);
	$t->get_ok("$b/room/list")->status_is(200)->json_is("/0/name" => 'Test room')->json_is('/0/id' => 1);
	$do_auth = 0;
	$t->post_ok("$b/room" => json => {})->status_is(401);
	$t->get_ok("$b/room/1")->status_is(200)->json_is('/name' => 'Test room')->json_is('/id' => 1);
	$do_auth = 1;
	$t->patch_ok("$b/room/1" => json => { altname => "foo" })->status_is(200)->json_is('/altname' => "foo");
	$t->patch_ok("$b/room/3" => json => { altname => "bar" })->status_is(404);
	$do_auth = 0;
	$t->patch_ok("$b/room/1" => json => { altname => "bar" })->status_is(401);
	$t->get_ok("$b/room/1")->status_is(200)->json_is('/altname' => 'foo')->json_is('/name' => 'Test room');
	$do_auth = 1;
	$t->post_ok("$b/room" => json => {"name" => "deletable"})->status_is(200)->json_is("/id" => 2)->json_is('/name' => 'deletable');
	$t->delete_ok("$b/room/2")->status_is(200);
	$do_auth = 0;
	$t->get_ok("$b/room/2")->status_is(404);

	# Talks
	$t->get_ok("$b/event/1/talk/list")->status_is(401);
	$do_auth = 1;
	$t->get_ok("$b/event/1/talk/list")->status_is(200)->json_is("" => []);
	my $nonce = $t->post_ok("$b/event/1/talk" => json => {room => 1,slug => 'test', starttime => '2020-05-30T10:30:00',endtime => '2020-05-30T10:35:00',title=>'Test',event=>1,upstreamid=>''})->status_is(200)->json_is('/title' => 'Test')->json_is('/room' => 1)->json_is('/id' => 1)->tx->res->json->{nonce};
	$t->get_ok("$b/event/1/talk/list")->status_is(200)->json_is('/0/title' => 'Test');
	$t->patch_ok("$b/event/1/talk/1" => json => {subtitle => 'also test'})->status_is(200)->json_is('/title' => 'Test')->json_is('/subtitle' => 'also test');
	$t->patch_ok("$b/event/1/talk/1" => json => {apologynote => 'sorry'})->status_is(200)->json_is('/apologynote' => 'sorry');
	# Talks by nonce
	$t->get_ok("$b/nonce/$nonce/talk")->status_is(200)->json_is("/id" => 1)->json_is('/apologynote' => 'sorry');
	
	# Talk data
	$t->get_ok("$b/nonce/$nonce/data")->status_is(200)->json_like("/start" => qr/^2020-05-30 10:30:00\+[0-9][0-9]/)->json_is("/start_iso" => "2020-05-30T10:30:00Z")->json_like("/end" => qr/^2020-05-30 10:35:00\+[0-9][0-9]/)->json_is("/end_iso" => "2020-05-30T10:35:00Z");

	# Tracks
	$do_auth = 0;
	$t->get_ok("$b/track/list")->status_is(401);
	$t->post_ok("$b/track" => json => { name => "test track" })->status_is(401);
	$do_auth = 1;
	$t->get_ok("$b/track/list")->status_is(200)->json_is([]);
	$t->post_ok("$b/track" => json => {name =>"test track", email => 'example@example.com', upstreamid => 'example'})->status_is(200)->json_is("/name" => "test track")->json_is("/email" => 'example@example.com')->json_is("/upstreamid" => 'example');
	$t->get_ok("$b/track/list")->status_is(200)->json_is('/0/upstreamid' => 'example');

	# Speakers
	$do_auth = 0;
	$t->get_ok("$b/speaker/search/Wouter")->status_is(401);
	$do_auth = 1;
	$t->get_ok("$b/speaker/search/Wouter")->status_is(200)->json_is("" => []);
	$t->post_ok("$b/speaker" => json => {name => "Wouter Verhelst", upstreamid => "foo"})->status_is(200)->json_is("/name" => "Wouter Verhelst")->json_is("/id" => 1);
	$t->get_ok("$b/speaker/search/Wouter")->status_is(200)->json_is("/0/name" => "Wouter Verhelst");
	$t->patch_ok("$b/speaker/1" => json => {email => 'w@uter.be'})->status_is(200)->json_is("/email" => 'w@uter.be')->json_is("/name" => "Wouter Verhelst");
	$t->get_ok("$b/speaker/1")->status_is(200)->json_is("/email" => 'w@uter.be')->json_is("/name" => "Wouter Verhelst");
	$t->post_ok("$b/speaker" => json => {name => "Tammy Verhelst"})->status_is(200)->json_is("/name" => "Tammy Verhelst")->json_is("/id" => 2);

	# Speakers/talks
	$do_auth = 0;
	$t->get_ok("$b/event/1/talk/1/speakers")->status_is(401);
	$do_auth = 1;
	$t->get_ok("$b/event/1/talk/1/speakers")->status_is(200)->json_is("" => []);
	$t->get_ok("$b/event/1/talk/2/speakers")->status_is(404);
	$t->put_ok("$b/event/1/talk/1/speakers" => json => [1])->status_is(200)->json_is("" => [1]);
	my $js = $t->post_ok("$b/event/1/talk/1/speakers" => json => [2])->status_is(200)->tx->res->json;
	ok(scalar(@$js) == 2, "correct number of speakers found");
	my @js = sort @$js;
	ok($js[0] == 1, "speaker 1 is assigned correctly");
	ok($js[1] == 2, "speaker 2 is assigned correctly");
	$t->put_ok("$b/event/1/talk/1/speakers" => json => [2])->status_is(200)->json_is("" => [2]);
	$t->post_ok("$b/event/1/talk/1/speakers" => json => [2])->status_is(400);
	$t->get_ok("$b/event/1/speaker/byupstream/foo")->status_is(200)->json_is("/name" => "Wouter Verhelst");
	$t->get_ok("$b/event/1/speaker/byupstream/bar")->status_is(404);
	$do_auth = 0;
	$t->get_ok("$b/event/1/speaker/byupstream/foo")->status_is(401);

	$t->get_ok("$b/event/1/talk/test/preroll")->status_is(200)->content_type_is("image/png");
	$t->get_ok("$b/event/1/talk/test/postroll")->status_is(200)->content_type_is("image/png");
	$t->get_ok("$b/event/1/talk/test/sorry")->status_is(200)->content_type_is("image/png");

	my $json = $t->get_ok("$b/config/legend")->status_is(200)->tx->res->json;
	foreach my $value(@{SReview::Talk::State->values}) {
		my $val_json = shift @$json;
		ok($value eq $val_json->{name}, "$value exists in module and legend at the same location");
	}
	ok(scalar(@$json) == 0, "no missing values in api");
}

if(!(exists($ENV{SREVIEWTEST_INSTALLED}) or exists($ENV{AUTOPKGTEST_TMP}))) {
	chdir('..');
	unlink('web/t');
}

done_testing;
