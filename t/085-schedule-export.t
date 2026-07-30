#!/usr/bin/perl -w

use v5.28;

use Test::More;
use Test::Mojo;
use Data::Dumper;
use DateTime::Format::Strptime;
use DateTime::Format::Pg;
use Mojo::File qw/path/;
use Cwd qw/abs_path/;
use File::Path qw/make_path remove_tree/;

use SReview::Config::Common;

my $config = SReview::Config::Common::setup;

$config->set(secret => "foo",
	outputdir => abs_path('t/outputdir'),
	inputglob => abs_path('t/inputdir') . "/*/*/*.mp4",
	pubdir => abs_path('t/pubdir'),
	preroll_template => abs_path('t/testvids/just-title.svg'),
	postroll_template => abs_path('t/testvids/just-title.svg'),
	apology_template => abs_path('t/testvids/just-title.svg'),
	event => "Test event",
);

if(exists($ENV{SREVIEWTEST_DB})) {
	$config->set(dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB});
}

use_ok 'SReview::Talk';

SKIP: {
	skip("Need a database to play with", 1) unless (exists($ENV{SREVIEWTEST_DB}) or exists($ENV{SREVIEWTEST_INSTALLED}) or exists($ENV{AUTOPKGTEST_TMP}));

	my $script;
	if(exists($ENV{SREVIEWTEST_INSTALLED}) or exists($ENV{AUTOPKGTEST_TMP})) {
		$script = "SReview::Web";
	} else {
		$script = path(__FILE__);
		$script = $script->dirname->child('..')->child('web')->child('sreview-web')->to_abs;
		symlink "../t", "web/t";
		chdir($script->dirname);
	}

	make_path('t/inputdir/room1/2017-11-10');
        symlink('../../../testvids/bbb.mp4', 't/inputdir/room1/2017-11-10/17:00:00.mp4');
	my $talk = SReview::Talk->new(talkid => 1);
	$talk->set_state('done');
	my $t = Test::Mojo->new($script);
	my $tx = $t->get_ok("/released")->status_is(200);
	my $parser = DateTime::Format::Strptime->new(pattern => "%F %T");
	my $start = $parser->parse_datetime('2017-11-10 17:00:00');
	$start->set_time_zone("local");
	my $end = $parser->parse_datetime('2017-11-10 17:00:10');
	$end->set_time_zone("local");
	$tx->json_is({
		conference => {
			title => 'Test event',
			date => [ '2017-11-10', '2017-11-10' ],
			video_formats => {
				default => {
					resolution => "854x480",
					vcodec => "vp9",
					acodec => "opus",
					bitrate => "750k",
				}
			}
		},
		videos => [{
			room => 'room1',
			video => 'Test event/room1/2017-11-10/test-talk.webm',
			title => 'Test talk',
			description => 'Test talk description',
			speakers => [
				'Speaker 1',
				'Speaker 2',
				'Speaker 3',
			],
			eventid => '1',
			start => substr(DateTime::Format::Pg->format_timestamptz($start), 0, -2),
			end => substr(DateTime::Format::Pg->format_timestamptz($end), 0, -2),
		}]
	});
}

remove_tree("t/inputdir");

done_testing;
