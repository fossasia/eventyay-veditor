#!/usr/bin/perl -w

use v5.28;
use strict;
use warnings;

use SReview::Talk;
use SReview::Config::Common;
use File::Which;
use Test::More;

my $config = SReview::Config::Common::setup;

SKIP: {
	skip "no synfig installed" unless defined(which('synfig'));
	use_ok("SReview::Template::Synfig");

	my $talk = SReview::Talk->new(talkid => 1);
	isa_ok($talk, "SReview::Talk");

	mkdir("animations");

	SReview::Template::Synfig::process_template("t/testvids/animated.sif", "animations/anim.png", $talk, $config);

	ok(-f "animations/anim.0120.png", "processing a Synfig animation generates 120 files");
	ok(! -f "animations/anim.0121.png", "processing a Synfig animation does not generate too many files");

	unlink(glob "animations/*png");
	rmdir("animations");
}

done_testing;
