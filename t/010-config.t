#!/usr/bin/perl -w

BEGIN {
	foreach my $key(keys %ENV) {
		if($key =~ /^SREVIEW_/) {
			delete $ENV{$key};
		}
	}
}

use strict;
use warnings;

use Test::More tests => 9;
use File::Temp qw/tempfile/;
use_ok('SReview::Config');

my $val;
local $SIG{__WARN__} = sub { $val = shift; };

my $config = SReview::Config->new('config');
ok($val =~ /^Warning: could not find configuration file config, falling back to defaults at t\/010-config\.t line \d+\.$/, 'loading nonexisting config produces a warning but succeeds');
isa_ok($config, 'SReview::Config');

$val = '';
$config = SReview::Config->new('./t/test.cf');
ok(length($val) == 0, 'loading an existing config file succeeds and prints no warning');

$config->define('test', 'testingk', 1);
my $rv = $config->dump();
my $expect = '# SReview configuration file
# ==========================
# This configuration file contains all the configuration options known to
# SReview. To change any configuration setting, you may either modify this
# configuration file, or you can run \'sreview-config --set=key=value -a
# update\'. The latter method will rewrite the whole configuration file,
# removing any custom comments. It is therefore recommended that you use
# one or the other, but not both. However, it will also write the default
# values for all known configuration items to this config file (in a
# commented-out fashion).
# 
# Every configuration option is preceded by a comment explaining what it
# does, and the legal values it can accept.

# Allow utf-8 strings
use utf8;

# test
# ----
# testingk
#$test = 1;

# Do not remove this, perl needs it
1;
';
ok($expect eq $rv, "Config dump output is as expected");
ok($config->describe('test') eq 'testingk', "Description of configuration value is as expected");
my ($f, $filename) = tempfile('configtest-XXXXXXXX', UNLINK => 1);
print $f '{';
eval {
	my $config = SReview::Config->new($filename);
};
ok(defined($@), "Trying to parse a syntactically invalid perl script produces an exception");
eval {
	my $val = $config->get('foo');
};
ok(defined($@), "Trying to read a config variable that does not exist produces an exception");
$val = $config->get('test');
ok($val == 1, "Reading data that does not exist yet produces the default");
