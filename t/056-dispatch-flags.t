#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use SReview::Config::Common;
use SReview::Db;
use SReview::Dispatch;
use DBI;

my $config = SReview::Config::Common::setup;

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 1) unless defined($ENV{SREVIEWTEST_DB});

	$config->set(
		dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB},
		event => 'Test event',
		query_limit => 0,
	);

	ok(SReview::Db::init($config), "Initializing the database was successful");
	ok(SReview::Db::selfdestruct(code => 0, init => 0), "Clobbering the database works");
	ok(SReview::Db::init($config), "Re-initializing the database after clobbering it was successful");

	my $dbh = DBI->connect($config->get('dbistring'), '', '', { RaiseError => 1, AutoCommit => 1 });

	$dbh->prepare("INSERT INTO rooms(id, name, altname, outputname) VALUES (1, 'room1', 'Room1', 'room1')")->execute();
	$dbh->prepare("INSERT INTO events(id, name, outputdir) VALUES(1, 'Test event', NULL)")->execute();

	my $insert = $dbh->prepare("INSERT INTO talks(id, room, slug, starttime, endtime, title, description, event, upstreamid, state, progress, flags) VALUES(?, 1, ?, '2017-11-10 17:00:00+00', '2017-11-10 17:00:10+00', ?, '', 1, ?, 'cutting', 'waiting', ?)" );

	$insert->execute(1, 't1', 'Talk 1', 'up1', '{"special": true}');
	$insert->execute(2, 't2', 'Talk 2', 'up2', '{"special": true, "skip": true}');
	$insert->execute(3, 't3', 'Talk 3', 'up3', '{"skip": true}');
	$insert->execute(4, 't4', 'Talk 4', 'up4', undef);

	my $state_actions = { cutting => 'sreview-skip <%== $talkid %>' };

	$config->set(dispatch_require_flags => [], dispatch_ignore_flags => []);
	my $rows = SReview::Dispatch::pending_talks($dbh, $config, $state_actions);
	cmp_ok(scalar(@{$rows}), '==', 4, 'No require/ignore flags yields all talks');

	$config->set(dispatch_require_flags => ['special'], dispatch_ignore_flags => []);
	$rows = SReview::Dispatch::pending_talks($dbh, $config, $state_actions);
	is_deeply([ sort map { $_->{id} } @{$rows} ], [1,2], 'Require flag selects only talks that have it');

	$config->set(dispatch_require_flags => [], dispatch_ignore_flags => ['skip']);
	$rows = SReview::Dispatch::pending_talks($dbh, $config, $state_actions);
	is_deeply([ sort map { $_->{id} } @{$rows} ], [1,4], 'Ignore flag filters out talks that have it');

	$config->set(dispatch_require_flags => ['special'], dispatch_ignore_flags => ['skip']);
	$rows = SReview::Dispatch::pending_talks($dbh, $config, $state_actions);
	is_deeply([ sort map { $_->{id} } @{$rows} ], [1], 'Require and ignore applied simultaneously');

	ok(SReview::Db::selfdestruct(code => 0, init => 0), "Clobbering the database after the test works");
	ok(SReview::Db::init($config), "Re-initializing the database after clobbering it at the end was successful");
}

done_testing;
