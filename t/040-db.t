#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More tests => 7;

use SReview::Db;
use SReview::Config;
use SReview::Config::Common;

use DBI;

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 7) unless defined($ENV{SREVIEWTEST_DB});

	my $warn;
	local $SIG{__WARN__} = sub { $warn = shift };

	my $config = SReview::Config::Common::setup;

	isa_ok($config, 'SReview::Config');

	$config->set(dbistring => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB});

	ok(SReview::Db::init($config), "Initializing the database was successful");
	ok(SReview::Db::selfdestruct(code => 0, init => 0), "Clobbering the database works");
	ok(SReview::Db::init($config), "Re-initializing the database after clobbering it was successful");
	my $db = DBI->connect($config->get('dbistring'), '', '', {AutoCommit => 1});
	ok(defined($db), "connecting to the database was successful");
	my $q = $db->prepare("SELECT * FROM raw_files");
	ok(defined($q), "preparing a query succeeds");
	ok(defined($q->execute), "running a query succeeds, and the tables exist");
}
