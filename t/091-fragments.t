#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use Test::Deep;
use SReview::Config::Common;
use SReview::Db;
use DBI;

my $config = SReview::Config::Common::setup;

sub setup_db {
	ok(SReview::Db::init($config), "Initializing the database was successful");
	ok(SReview::Db::selfdestruct(code => 0, init => 0), "Clobbering the database works");
	ok(SReview::Db::init($config), "Re-initializing the database after clobbering it was successful");

	my $dbh = DBI->connect($config->get('dbistring'), '', '', { RaiseError => 1, AutoCommit => 1 });
	$dbh->prepare("INSERT INTO rooms(id, name, altname, outputname) VALUES (1, 'room1', 'Room1', 'room1')")->execute();
	$dbh->prepare("INSERT INTO events(id, name, outputdir) VALUES(1, 'Test event', NULL)")->execute();
	$dbh->prepare("INSERT INTO tracks(id, name) VALUES(1, 'Track 1')")->execute();
	return $dbh;
}

sub insert_talk {
	my ($dbh, %p) = @_;
	my $talkid = $p{talkid} // 1;
	my $start = $p{start} // '2017-11-10 17:00:00+00';
	my $end = $p{end} // '2017-11-10 17:00:10+00';
	my $active_stream = defined($p{active_stream}) ? $p{active_stream} : '';

	my $st = $dbh->prepare(q{INSERT INTO talks(id, room, slug, starttime, endtime, title, subtitle, description, event, upstreamid, track, state, progress, apologynote, active_stream, extra_data, flags) VALUES(?, 1, 'test-talk', ?, ?, 'Test talk', 'Sub', 'Test talk description', 1, 'up1', 1, 'waiting_for_files', 'waiting', NULL, ?, '{"foo":"bar"}', '{"a":true}') RETURNING nonce});
	$st->execute($talkid, $start, $end, $active_stream);
	return $st->fetchrow_arrayref->[0];
}

sub insert_raw {
	my ($dbh, %p) = @_;
	my $id = $p{id};
	my $start = $p{start};
	my $end = $p{end};
	my $stream = defined($p{stream}) ? $p{stream} : '';
	my $filename = $p{filename} // "room1/raw$id.mkv";
	$dbh->prepare("INSERT INTO raw_files(id, filename, room, starttime, endtime, stream) VALUES(?, ?, 1, ?, ?, ?)")->execute($id, $filename, $start, $end, $stream);
}

sub sum_len {
	my ($rows, $which) = @_;
	my $sum = 0;
	foreach my $r(@$rows) {
		next if $r->{talkid} != $which;
		$sum += 0 + $r->{raw_length_corrected};
	}
	return $sum;
}

sub empty_len {
	my ($rows, $which) = @_;
	foreach my $r(@$rows) {
		return 0 if $r->{talkid} == $which;
	}
	return 1;
}

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 1)
		unless defined($ENV{SREVIEWTEST_DB});

	$config->set(
		dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB},
		output_subdirs => [ 'eventid', 'event', 'room', 'date', 'year' ],
		pubdir => '/srv/sreview/web/public/video',
		outputdir => '/srv/sreview/output',
		preview_exten => 'webm',
	);

	use_ok('SReview::Talk');

	my $twenty = 20 * 60;
	my $talklen = 10;
	my $main_expected = $talklen;

	# Scenario 1: Single raw file provides at least 20 minutes pre + talk + 20 minutes post
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw(
			$dbh,
			id => 1,
			start => '2017-11-10 16:40:00+00',
			end => '2017-11-10 17:20:10+00',
		);
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre total is 20 minutes when available in one file');
		cmp_ok(sum_len($rows, 1), '==', $main_expected, 'main total is full talk length when available');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post total is 20 minutes when available in one file');
	}

	# Scenario 2: Pre spans multiple raw files but totals >= 20 minutes
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw($dbh, id => 1, start => '2017-11-10 16:40:00+00', end => '2017-11-10 16:55:00+00');
		insert_raw($dbh, id => 2, start => '2017-11-10 16:55:00+00', end => '2017-11-10 17:20:10+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre total is 20 minutes when spanning multiple files');
		cmp_ok(sum_len($rows, 1), '==', $main_expected, 'main total is full talk length when available (multiple files)');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post total is 20 minutes when available (multiple files)');
	}

	# Scenario 3: Not enough pre video available => pre < 20 minutes
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw($dbh, id => 1, start => '2017-11-10 16:50:00+00', end => '2017-11-10 17:20:10+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, -1), '==', 10 * 60, 'pre total is less than 20 minutes if not enough available');
		cmp_ok(sum_len($rows, 1), '==', $main_expected, 'main total still full talk length when available');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post total is 20 minutes when available');
	}

	# Scenario 4: Not enough post video available => post < 20 minutes
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw($dbh, id => 1, start => '2017-11-10 16:40:00+00', end => '2017-11-10 17:10:00+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre total is 20 minutes when available');
		cmp_ok(sum_len($rows, 1), '==', $main_expected, 'main total is full talk length when available');
		cmp_ok(sum_len($rows, -2), '==', (9 * 60 + 50), 'post total is less than 20 minutes if not enough available');
	}

	# Scenario 5: Main video missing at the beginning => main shorter, pre empty
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		# starts 5 seconds after talk start
		insert_raw($dbh, id => 1, start => '2017-11-10 17:00:05+00', end => '2017-11-10 17:20:10+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, 1), '==', 5, 'main total is reduced if missing beginning');
		ok(empty_len($rows, -1), 'pre is empty if main is missing at the beginning');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post still 20 minutes when available');
	}

	# Scenario 6: Main video missing at the end => main shorter, post empty
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		# ends 5 seconds before talk end
		insert_raw($dbh, id => 1, start => '2017-11-10 16:40:00+00', end => '2017-11-10 17:00:05+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, 1), '==', 5, 'main total is reduced if missing end');
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre still 20 minutes when available');
		ok(empty_len($rows, -2), 'post is empty if main is missing at the end');
	}

	# Scenario 7: Main spans multiple raw files but has full coverage
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw($dbh, id => 1, start => '2017-11-10 16:40:00+00', end => '2017-11-10 17:00:05+00');
		insert_raw($dbh, id => 2, start => '2017-11-10 17:00:05+00', end => '2017-11-10 17:20:10+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, 1), '==', $main_expected, 'main total equals talk length when covered by multiple files');
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre total equals 20 minutes');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post total equals 20 minutes');
	}

	# Scenario 8: Gap inside main (missing middle) => main shorter
	{
		my $dbh = setup_db();
		insert_talk($dbh);
		insert_raw($dbh, id => 1, start => '2017-11-10 16:40:00+00', end => '2017-11-10 17:00:05+00');
		insert_raw($dbh, id => 2, start => '2017-11-10 17:00:08+00', end => '2017-11-10 17:20:10+00');
		my $talk = SReview::Talk->new(talkid => 1);
		my $rows = $talk->video_fragments;
		cmp_ok(sum_len($rows, 1), '==', 7, 'main total is reduced if there is a gap inside main');
		cmp_ok(sum_len($rows, -1), '==', $twenty, 'pre total equals 20 minutes');
		cmp_ok(sum_len($rows, -2), '==', $twenty, 'post total equals 20 minutes');
	}
}

done_testing;
