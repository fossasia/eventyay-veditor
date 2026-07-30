#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

use SReview::Config::Common;

{
	local %ENV = %ENV;
	delete @ENV{grep { /^SREVIEW_/ } keys %ENV};

	is(SReview::Config::Common::get_default_cfile(), "/etc/sreview/config.pm", "default config file is /etc/sreview/config.pm when SREVIEW_WDIR is unset and local config.pm does not exist");

	$ENV{SREVIEW_WDIR} = "/tmp";
	is(SReview::Config::Common::get_default_cfile(), "/tmp/config.pm", "default config file uses SREVIEW_WDIR when set");
}

{
	local %ENV = %ENV;
	delete @ENV{grep { /^SREVIEW_/ } keys %ENV};

	is(SReview::Config::Common::compute_dbistring(), undef, "compute_dbistring returns undef when components not set");

	$ENV{SREVIEW_DBICOMPONENTS} = "dbname host";
	$ENV{SREVIEW_DBI_DBNAME} = "sreview";
	$ENV{SREVIEW_DBI_HOST} = "localhost";
	is(SReview::Config::Common::compute_dbistring(), "dbi:Pg:dbname=sreview;host=localhost", "compute_dbistring concatenates components in order");
}

{
	local %ENV = %ENV;
	delete @ENV{grep { /^SREVIEW_/ } keys %ENV};

	is(SReview::Config::Common::compute_accessconfig(), undef, "compute_accessconfig returns undef unless both access+secret are set");

	$ENV{SREVIEW_S3_DEFAULT_ACCESSKEY} = "AK";
	$ENV{SREVIEW_S3_DEFAULT_SECRETKEY} = "SK";
	my $cfg = SReview::Config::Common::compute_accessconfig();
	is_deeply($cfg, { default => { aws_access_key_id => "AK", aws_secret_access_key => "SK" } }, "compute_accessconfig returns minimal default config");

	$ENV{SREVIEW_S3_DEFAULT_SECURE} = 0;
	$ENV{SREVIEW_S3_DEFAULT_HOST} = "minio";
	$ENV{SREVIEW_S3_EXTRA_CONFIGS} = '{"input":{"host":"other"}}';
	$cfg = SReview::Config::Common::compute_accessconfig();
	is($cfg->{secure}, 0, "secure is propagated when set");
	is($cfg->{host}, "minio", "host is propagated when set");
	is_deeply($cfg->{input}, { host => "other" }, "extra configs are merged");
}

done_testing;
