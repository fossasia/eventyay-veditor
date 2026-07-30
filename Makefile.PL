#!/usr/bin/perl -w

use strict;
use warnings;

use ExtUtils::MakeMaker;
use ExtUtils::Depends;

my $eud = ExtUtils::Depends->new(qw/Alien::ffmpeg/);

WriteMakefile(
	NAME	=> "SReview",
	ABSTRACT_FROM => "lib/SReview.pm",
	VERSION_FROM => "lib/SReview.pm",
	AUTHOR => [
		'Wouter Verhelst <w@uter.be>',
	],
	PREREQ_PM => {
		'Media::Convert' => "1.5.1",
		'Mojo::JSON' => 0,
		'Mojo::Pg' => 0,
		'Mojolicious::Plugin::OpenAPI' => '>= 4.03',
		'Moose' => 0,
		'MooseX::ClassAttribute' => 0,
		'Class::Type::Enum' => 0,
		'Crypt::PRNG' => 0,
		'DateTime' => 0,
		'DateTime::Format::ISO8601' => 0,
		'DateTime::Format::Pg' => 0,
		'Net::Amazon::S3' => 0,
		'Net::SSH::AuthorizedKeysFile' => 0,
		'Net::SSH2' => 0,
		'Text::Format' => 0,
	},
	TEST_REQUIRES => {
		'Test::More' => 0,
		'YAML::XS' => 0,
	},
	CONFIGURE_REQUIRES => {
		'ExtUtils::Depends' => 0,
	},
	CONFIGURE_REQUIRES => {
		'ExtUtils::Depends' => 0,
	},
	EXE_FILES => [
		'scripts/sreview-autoreview',
		'scripts/sreview-cut',
		'scripts/sreview-config',
		'scripts/sreview-copy',
		'scripts/sreview-detect',
		'scripts/sreview-dispatch',
		'scripts/sreview-skip',
		'scripts/sreview-user',
		'scripts/sreview-notify',
		'scripts/sreview-reply',
		'scripts/sreview-upload',
		'scripts/sreview-transcode',
		'scripts/sreview-transcribe',
		'scripts/sreview-notranscode',
		'scripts/sreview-titles',
		'scripts/sreview-previews',
		'scripts/sreview-inject',
		'scripts/sreview-inject-job',
		'scripts/sreview-import',
		'web/sreview-web',
	],
	META_MERGE => {
		"meta-spec" => { version => 2 },
		resources => {
			repository => {
				type => "git",
				url => "https://github.com/yoe/SReview.git",
				web => "https://github.com/yoe/SReview",
			},
			homepage => "https://yoe.github.io/SReview",
		}
	},
	$eud->get_makefile_vars
);
