#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More tests => 17;
use SReview::Config::Common;
use Data::Dumper;
use File::Copy;
use Mojo::JSON qw/decode_json/;

my $config = SReview::Config::Common::setup;

$config->set("outputdir", "t/testvids");
mkdir("t/target");
$config->set("pubdir", "t/target");
$config->set("accessmethods", {input => "direct", output => "direct", intermediate => "direct"});

use_ok("SReview::Files::Factory");

my $coll = SReview::Files::Factory->create("output", "t/testvids");

isa_ok($coll, "SReview::Files::Collection::Base");
isa_ok($coll, "SReview::Files::Collection::direct");
my $children = $coll->children;
isa_ok($children, "ARRAY");
my $child = $children->[0];
isa_ok($child, "SReview::Files::Access::Base");
isa_ok($child, "SReview::Files::Access::direct");
ok(defined($child->filename), "child has a filename");

my $coll2 = SReview::Files::Factory->create("intermediate", "t/target");
my $newfile = $coll2->add_file(relname => $child->relname);
copy($child->filename, $newfile->filename);
$newfile->store_file;

ok($coll2->has_file($child->relname), "file copies to new collection");

my $subfile = $coll2->add_file(relname => "foo/" . $child->relname);
copy($child->filename, $subfile->filename);
ok($coll2->has_file("foo/" . $child->relname), "file copies to new collection in subdir");
$subfile->store_file;

$coll2->delete_files(files => ["t/target/foo/"]);

ok(!($coll2->has_file("foo" . $child->relname)), "file can be deleted by prefix");

$coll2->delete_files(files => [join("/", $coll2->baseurl, $child->relname)]);

SKIP: {
	skip("Can't test S3 work unless the s3_access_config configuration is valid", 7) unless (exists($ENV{SREVIEWTEST_BUCKET}) && exists($ENV{SREVIEWTEST_S3_CONFIG}));

	$config->set("s3_access_config", decode_json($ENV{SREVIEWTEST_S3_CONFIG}));
	$config->set("accessmethods", {input => "S3", output => "S3", intermediate => "S3"});
	$config->set("outputdir", $ENV{SREVIEWTEST_BUCKET});
	$coll = SReview::Files::Factory->create("output", $ENV{SREVIEWTEST_BUCKET});

	isa_ok($coll, "SReview::Files::Collection::Base");
	isa_ok($coll, "SReview::Files::Collection::S3");

	my $new = $coll->add_file(relname => $child->relname);
	ok($new->relname eq $child->relname, "creating a file with a relname from another bucket creates the same relname");
	copy($child->filename, $new->filename);
	$new->store_file;
	$children = $coll->children;
	ok($coll->has_file($new->relname), "adding a file creates it in the bucket");
	$new->delete;
	$coll = SReview::Files::Factory->create("output", $ENV{SREVIEWTEST_BUCKET});
	ok(!($coll->has_file($new->relname)), "deleting a file removes it");

	$new = $coll->add_file(relname => "foo/" . $child->relname);
	copy($child->filename, $new->filename);
	$new->store_file;
	$coll = SReview::Files::Factory->create("output", $ENV{SREVIEWTEST_BUCKET});
	ok($coll->has_file($new->relname), "adding a file with a subdir works");
	$coll->delete_files(files => [$ENV{SREVIEWTEST_BUCKET} . "/foo"]);
	$coll = SReview::Files::Factory->create("output", $ENV{SREVIEWTEST_BUCKET});
	ok(!($coll->has_file($new->relname)), "file can be deleted by prefix");
}
