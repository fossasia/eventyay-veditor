#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use DBI;
use SReview::Talk::State;
use YAML::XS;
use SReview::API;

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 1) unless defined($ENV{SREVIEWTEST_DB});

	# Fetch values from the database
	my $db = DBI->connect('dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB});
	my $st = $db->prepare("SELECT enum_range(null::talkstate)");
	$st->execute;
	my $val = $st->fetchrow_arrayref()->[0];
	$val =~ s/(\{|\})//g;
	my @values_db = split /,/, $val;

	# Fetch values from the API definition
	$_ = <SReview::API::DATA>;
	my $obj;
	{
		local $/ = undef;
		my $yaml = <SReview::API::DATA>;
		$obj = Load $yaml;
		close SReview::API::DATA;
	}
	my @values_api = @{$obj->{components}{schemas}{Talk}{properties}{state}{enum}};

	# Fetch values from the module
	my @values_mod = @{SReview::Talk::State->values};
	foreach my $value(@values_db) {
		isa_ok(SReview::Talk::State->new($value), "SReview::Talk::State");
		ok($value eq shift @values_mod, "$value exists in db and module at same location");
		ok($value eq shift @values_api, "$value exists in db and API at same location");
	}
	ok(scalar(@values_mod) == 0, "no spurious values in module");
	ok(scalar(@values_api) == 0, "no spurious values in api");
}

done_testing;
