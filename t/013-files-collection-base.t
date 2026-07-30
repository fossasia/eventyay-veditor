#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;

use SReview::Files::Collection::direct;

my $tmp = tempdir(CLEANUP => 1);

my $base = File::Spec->catdir($tmp, "coll");
make_path($base);

# Create some files
open(my $fh1, ">", File::Spec->catfile($base, "a")) or die $!;
print $fh1 "x";
close($fh1);

make_path(File::Spec->catdir($base, "dir"));
open(my $fh2, ">", File::Spec->catfile($base, "dir", "b")) or die $!;
print $fh2 "y";
close($fh2);

my $coll = SReview::Files::Collection::direct->new(baseurl => $base);
isa_ok($coll, 'SReview::Files::Collection::direct');

is($coll->globpattern, join('/', $base, '*'), 'globpattern derived from baseurl');

ok($coll->has_file('a'), 'has_file detects existing top-level file');
ok(!$coll->has_file('nope'), 'has_file returns false for missing file');

# delete_files with relnames should delete matching prefix
$coll->delete_files(relnames => ['dir']);
ok(!-e File::Spec->catfile($base, 'dir', 'b'), 'delete_files deletes files inside directories when prefix matches');

# delete_files with non-existing should not die
$coll->delete_files(relnames => ['does-not-exist']);
pass('delete_files ignores non-existing relname');

done_testing;
