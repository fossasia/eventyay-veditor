#!/usr/bin/perl

use strict;
use warnings;

use Net::Amazon::S3;
use Mojo::JSON qw/decode_json/;

exit 0 unless exists($ENV{SREVIEWTEST_S3_CONFIG});
exit 0 unless exists($ENV{SREVIEWTEST_BUCKET});

my $config = decode_json($ENV{SREVIEWTEST_S3_CONFIG});

my $s3 = Net::Amazon::S3->new($config->{default});

$s3->add_bucket({bucket => $ENV{SREVIEWTEST_BUCKET}});
