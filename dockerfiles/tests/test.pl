#!/usr/bin/perl -w

use strict;
use warnings;

use Mojo::UserAgent;
use Mojo::JSON qw/decode_json/;
use Mojo::URL;
use SReview::Talk;
use SReview::Config::Common;
use Data::Dumper;

my $ua = Mojo::UserAgent->new;

my $config = SReview::Config::Common::setup();

my $baseurl = Mojo::URL->new($config->get('urlbase'));

my $res = $ua->post(Mojo::URL->new("/login_post")->base($baseurl)->to_abs => form => { email => $config->get('adminuser'), pass => $config->get('adminpw') })->result;

$res->is_redirect or die "error " . $res->code . ": " . $res->message;

my $talk = SReview::Talk->new(talkid => 1);

$res = $ua->get(Mojo::URL->new("/r/" . $talk->nonce. "/data")->base($baseurl)->to_abs)->result;

$res->is_success or die "error " . $res->code . ": " . $res->message;

my $json = decode_json($res->body);

print Dumper($json);
