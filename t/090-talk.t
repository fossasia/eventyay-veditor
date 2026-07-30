#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use Test::Deep;
use SReview::Config::Common;
use SReview::Db;
use DBI;

my $config = SReview::Config::Common::setup;

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 1) unless defined($ENV{SREVIEWTEST_DB});

	$config->set(
		dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB},
		output_subdirs => [ 'eventid', 'event', 'room', 'date', 'year' ],
		pubdir => '/srv/sreview/web/public/video',
		outputdir => '/srv/sreview/output',
		preview_exten => 'webm',
	);

	ok(SReview::Db::init($config), "Initializing the database was successful");
	ok(SReview::Db::selfdestruct(code => 0, init => 0), "Clobbering the database works");
	ok(SReview::Db::init($config), "Re-initializing the database after clobbering it was successful");

	use_ok('SReview::Talk');

	my $dbh = DBI->connect($config->get('dbistring'), '', '', { RaiseError => 1, AutoCommit => 1 });

	$dbh->prepare("INSERT INTO rooms(id, name, altname, outputname) VALUES (1, 'room1', 'Room1', 'room1')")->execute();
	$dbh->prepare("INSERT INTO events(id, name, outputdir) VALUES(1, 'Test event', NULL)")->execute();
	$dbh->prepare("INSERT INTO tracks(id, name) VALUES(1, 'Track 1')")->execute();
	my $st = $dbh->prepare("INSERT INTO talks(id, room, slug, starttime, endtime, title, subtitle, description, event, upstreamid, track, state, progress, apologynote, active_stream, extra_data, flags) VALUES(1, 1, 'test-talk', '2017-11-10 17:00:00+00', '2017-11-10 17:00:10+00', 'Test talk', 'Sub', 'Test talk description', 1, 'up1', 1, 'waiting_for_files', 'waiting', NULL, '', '{\"foo\":\"bar\"}', '{\"a\":true}') RETURNING nonce");
	$st->execute();
	my $nonce = $st->fetchrow_arrayref->[0];

	$dbh->prepare("INSERT INTO speakers(id, name, email, upstreamid) VALUES(1, 'Speaker 1', 's1\@example.com', 's1')")->execute();
	$dbh->prepare("INSERT INTO speakers(id, name, email, upstreamid) VALUES(2, 'Speaker 2', NULL, 's2')")->execute();
	$dbh->prepare("INSERT INTO speakers_talks(speaker, talk) VALUES(1, 1)")->execute();
	$dbh->prepare("INSERT INTO speakers_talks(speaker, talk) VALUES(2, 1)")->execute();

	$dbh->prepare("INSERT INTO raw_files(id, filename, room, starttime, endtime, stream) VALUES(1, 'room1/2017-11-10/17:00:00.mp4', 1, '2017-11-10 16:40:00+00', '2017-11-10 17:20:10+00', '')")->execute();

	my $talk = SReview::Talk->new(talkid => 1);
	isa_ok($talk, 'SReview::Talk');

	ok($talk->talkid == 1, 'talkid is correct');
	ok($talk->nonce eq $nonce, 'nonce is loaded from the database');
	ok($talk->slug eq 'test-talk', 'slug resolves correctly');
	ok($talk->title eq 'Test talk', 'title resolves correctly');
	ok($talk->subtitle eq 'Sub', 'subtitle resolves correctly');
	ok($talk->description eq 'Test talk description', 'description resolves correctly');
	ok($talk->room eq 'room1', 'room resolves correctly');
	ok($talk->roomid == 1, 'roomid resolves correctly');
	ok($talk->eventname eq 'Test event', 'eventname resolves correctly');
	ok($talk->track_name eq 'Track 1', 'track_name resolves correctly');
	ok(ref($talk->state) eq 'SReview::Talk::State' && $talk->state eq 'waiting_for_files', 'state resolves correctly');
	ok(ref($talk->progress) eq 'SReview::Talk::Progress' && $talk->progress eq 'waiting', 'progress resolves correctly');
	ok($talk->active_stream eq '', 'active_stream resolves correctly');

	cmp_deeply($talk->extra_data, { foo => 'bar' }, 'extra_data resolves correctly');
	cmp_deeply($talk->flags, { a => bool(1) }, 'flags resolves correctly');

	my $relname = join("/", substr($talk->nonce, 0, 1), substr($talk->nonce, 1, 2), substr($talk->nonce, 3), $talk->has_correction("serial") ? $talk->corrections->{serial} : 0);
	ok($talk->workdir eq "/srv/sreview/web/public/video/$relname", 'workdir resolves correctly');
	ok($talk->finaldir eq "/srv/sreview/output/1/Test event/room1/2017-11-10/2017", 'finaldir resolves correctly');

	cmp_deeply(
		$talk->speakerlist,
		bag('Speaker 1', 'Speaker 2'),
		'speakerlist contains expected speakers'
	);
	ok($talk->speakers =~ /Speaker 1/ && $talk->speakers =~ /Speaker 2/, 'speakers string contains expected speakers');

	cmp_deeply(
		$talk->corrections,
		{ offset_start => num(0), length_adj => num(0), offset_audio => num(0), audio_channel => num(0) },
		'Corrections are set correctly by default'
	);

	cmp_deeply(
		$talk->video_fragments,
		[
			{ talkid => num(-1), rawid => num(1), raw_filename => 'room1/2017-11-10/17:00:00.mp4', fragment_start => num(0), raw_length => num(40 * 60 + 10), raw_length_corrected => num(20 * 60) },
			{ talkid => num(1), rawid => num(1), raw_filename => 'room1/2017-11-10/17:00:00.mp4', fragment_start => num(20 * 60), raw_length => num(40 * 60 + 10), raw_length_corrected => num(10) },
			{ talkid => num(-2), rawid => num(1), raw_filename => 'room1/2017-11-10/17:00:00.mp4', fragment_start => num(20 * 60 + 10), raw_length => num(40 * 60 + 10), raw_length_corrected => num(20 * 60) },
		],
		'Video fragments are found correctly'
	);

	$dbh->prepare("UPDATE talks SET slug='new-slug', title='New title', subtitle='New sub', description='New desc', apologynote='sorry', upstreamid='up2', state='broken', progress='failed', active_stream='stream1', extra_data='{\"x\":1}', flags='{\"b\":false}' WHERE id=1")->execute();
	$dbh->prepare("UPDATE rooms SET name='roomX', outputname='roomX' WHERE id=1")->execute();
	$dbh->prepare("UPDATE events SET name='Event X' WHERE id=1")->execute();
	$dbh->prepare("UPDATE tracks SET name='Track X' WHERE id=1")->execute();

	my $talk2 = SReview::Talk->new(talkid => 1);
	isa_ok($talk2, 'SReview::Talk');
	ok($talk2->slug eq 'new-slug', 'DB update reflects in slug');
	ok($talk2->title eq 'New title', 'DB update reflects in title');
	ok($talk2->subtitle eq 'New sub', 'DB update reflects in subtitle');
	ok($talk2->description eq 'New desc', 'DB update reflects in description');
	ok($talk2->apology eq 'sorry', 'DB update reflects in apology');
	ok($talk2->upstreamid eq 'up2', 'DB update reflects in upstreamid');
	ok($talk2->room eq 'roomX', 'DB update reflects in room');
	ok($talk2->eventname eq 'Event X', 'DB update reflects in eventname');
	ok($talk2->track_name eq 'Track X', 'DB update reflects in track_name');
	ok($talk2->active_stream eq 'stream1', 'DB update reflects in active_stream');
	ok(ref($talk2->state) eq 'SReview::Talk::State' && $talk2->state eq 'broken', 'DB update reflects in state');
	ok(ref($talk2->progress) eq 'SReview::Talk::Progress' && $talk2->progress eq 'failed', 'DB update reflects in progress');
	cmp_deeply($talk2->extra_data, { x => 1 }, 'DB update reflects in extra_data');
	cmp_deeply($talk2->flags, { b => bool(0) }, 'DB update reflects in flags');

	$talk2->comment("First comment");
	$talk2->done_correcting;
	my $talk3 = SReview::Talk->new(talkid => 1);
	ok(defined($talk3->comment), 'comment is loaded after writing comment');
	ok($talk3->comment =~ /First comment/, 'comment is written and loaded');
	ok($talk3->first_comment eq "First comment", 'first_comment is written and loaded');

	$talk3->add_correction(offset_start => 2);
	$talk3->done_correcting;
	my $talk4 = SReview::Talk->new(talkid => 1);
	ok($talk4->corrections->{offset_start} == 2, 'Corrections are written to the database');
	ok($talk4->corrections->{length_adj} == -2, 'Start offset changes length adjustment');
	ok($talk4->corrections->{serial} == 2, 'Setting corrections bumps the serial');
}

done_testing;
