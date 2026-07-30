#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use File::Which;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Copy qw/copy/;
use Time::HiRes qw/sleep/;

use SReview::Config::Common;
use SReview::Files::Factory;
use SReview::Talk;
use SReview::Credits qw/ensure_credit_preview/;

my $config = SReview::Config::Common::setup;

$config->set("pubdir", "t/target");
$config->set("accessmethods", {input => "direct", output => "direct", intermediate => "direct"});

my $talk;
{
	package TalkStub;
	use Moose;
	extends 'SReview::Talk';

	has '+talkid' => (
		required => 0,
		default => 1,
		trigger => undef,
	);

	sub _load_nonce { 'abc123' }
	sub _load_relative_name { 'a/bc/123/0' }
	sub _load_apology { '' }
	sub _load_speakers { 'Test Speaker' }
	sub _load_room { 'Test Room' }
	sub _load_title { 'Test Title' }
	sub _load_subtitle { 'Test Subtitle' }
	sub _load_date { '2020-01-01' }
}

mkdir("t/target") unless -d "t/target";
my $coll = SReview::Files::Factory->create("intermediate", $config->get("pubdir"));

my $tmpdir = tempdir('creditprevXXXXXX', DIR => '.', CLEANUP => 1);

open my $fh, '>', "$tmpdir/t.pl" or die $!;
print $fh "print \"x\\n\";\n";
close $fh;

$config->set(
	workdir => $tmpdir,
	preroll_template => "t/testvids/just-title.svg",
	postroll_template => "t/testvids/just-title.svg",
	apology_template => "t/testvids/just-title.svg",
);

$talk = TalkStub->new;

make_path("t/target/" . $talk->relative_name);
my $main = $coll->add_file(relname => $talk->relative_name . "/main.mkv");
copy("t/testvids/bbb.mp4", $main->filename) or die $!;
$main->store_file;

SKIP: {
	skip "no inkscape installed", 4 unless defined(which('inkscape'));
	$config->set(template_format => 'svg');

	my $res = ensure_credit_preview('pre', $talk, $config, $coll, 1);
	ok(defined($res) && $res->{content_type} eq 'image/png', "svg preroll returns png");
	ok(-f $res->{filename}, "svg preroll file exists");

	my $outname = $res->{filename};
	my $mtime1 = (stat($outname))[9];
	sleep 1.1;
	ensure_credit_preview('pre', $talk, $config, $coll, undef);
	my $mtime2 = (stat($outname))[9];
	is($mtime2, $mtime1, "svg preroll not regenerated without force");

	sleep 1.1;
	ensure_credit_preview('pre', $talk, $config, $coll, 1);
	my $mtime3 = (stat($outname))[9];
	ok($mtime3 > $mtime2, "svg preroll regenerated with force");
}

SKIP: {
	skip "no synfig installed", 2 unless defined(which('synfig'));
	skip "no ffmpeg installed", 2 unless defined(which('ffmpeg'));
	$config->set(template_format => 'synfig');

	my $res = ensure_credit_preview('pre', $talk, $config, $coll, 1);
	ok(defined($res) && $res->{content_type} eq 'video/webm', "synfig preroll returns webm");
	ok(-f $res->{filename}, "synfig preroll file exists");
}

done_testing;
