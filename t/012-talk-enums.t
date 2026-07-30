#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

use SReview::Talk::State;
use SReview::Talk::Progress;

{
	my $s = SReview::Talk::State->new('waiting_for_files');
	isa_ok($s, 'SReview::Talk::State');
	is("$s", 'waiting_for_files', 'state stringifies to symbol');

	++$s;
	is("$s", 'cutting', 'state increments to next value');

	--$s;
	is("$s", 'waiting_for_files', 'state decrements to previous value');
}

{
	my $s = SReview::Talk::State->new('injecting');
	++$s;
	is("$s", 'generating_previews', 'injecting increments to generating_previews');
}

{
	my $p = SReview::Talk::Progress->new('waiting');
	isa_ok($p, 'SReview::Talk::Progress');
	is("$p", 'waiting', 'progress stringifies to symbol');

	++$p;
	is("$p", 'scheduled', 'progress increments');

	--$p;
	is("$p", 'waiting', 'progress decrements');
}

done_testing;
