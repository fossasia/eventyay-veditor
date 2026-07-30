#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More tests => 19;

use Cwd 'abs_path';

$ENV{SREVIEW_WDIR} = abs_path('.');

use DBI;
use JSON::MaybeXS;
use Media::Convert::Asset;
use SReview::Config::Common;
use File::Path qw/make_path remove_tree/;
use_ok("SReview::Files::Factory");

sub ffprobe_start_times {
	my ($fn) = @_;
	my @cmd = (
		'ffprobe',
		'-loglevel', 'quiet',
		'-show_entries', 'stream=codec_type,start_time',
		'-print_format', 'json',
		$fn,
	);
	print "running: '", join("' '", @cmd), "'\n";
	open my $jsonpipe, '-|:encoding(UTF-8)', @cmd;
	my $json = '';
	while (my $line = <$jsonpipe>) {
		$json .= $line;
	}
	close $jsonpipe;
	my $data = decode_json($json);
	my %rv;
	foreach my $stream (@{$data->{streams}}) {
		next unless defined($stream->{codec_type});
		next unless defined($stream->{start_time});
		$rv{$stream->{codec_type}} = 0 + $stream->{start_time};
	}
	return \%rv;
}

sub run {
	my @command = @_;

	print "running: '", join("' '", @command), "'\n";
	system(@command) == 0 or die "system @command failed: $?";
}

my $scriptpath;

if(-f "/usr/bin/sreview-detect") {
	$scriptpath = "/usr/bin";
} else {
	$scriptpath = "./scripts/";
}

SKIP: {
	skip("Can't test database work unless the SREVIEWTEST_DB environment variable points to a database which we may clobber and recreate", 18) unless defined($ENV{SREVIEWTEST_DB});

	# Prepare an input directory
	make_path('t/inputdir/room1/2017-11-10');
	symlink('../../../testvids/bbb.mp4', 't/inputdir/room1/2017-11-10/17:00:00.mp4');

	# Prepare the configuration
	my @outputopts;
	if(exists($ENV{SREVIEWTEST_S3_CONFIG}) && exists($ENV{SREVIEWTEST_BUCKET})) {
		$ENV{SREVIEW_ACCESSMETHODS}='{"input":"direct","intermediate":"S3","output":"direct"}';
		$ENV{SREVIEW_S3_ACCESS_CONFIG}=$ENV{SREVIEWTEST_S3_CONFIG};
		@outputopts = ("--set", "pubdir=" . $ENV{SREVIEWTEST_BUCKET});
	} else {
		@outputopts = ("--set", "pubdir=" . abs_path("t/pubdir"));
	}
	$ENV{SREVIEW_OUTPUT_PROFILES}='["webm","copy"]';
	run($^X, "-I", $INC[0], "$scriptpath/sreview-config", "--action", "update", "--set", "dbistring=dbi:Pg:dbname=" . $ENV{SREVIEWTEST_DB}, "--set", "inputglob=" . abs_path("t/inputdir") . "/*/*/*", "--set", "outputdir=" . abs_path('t/outputdir'), "--set", "preroll_template=" . abs_path("t/testvids/just-title.svg"), "--set", "postroll_template=" . abs_path("t/testvids/just-title.svg"), @outputopts, "--set", "event=Test event");
	delete $ENV{SREVIEW_OUTPUT_PROFILES};

	ok(-f 'config.pm', "running sreview-config with -a update creates a config.pm");

	my $config = SReview::Config::Common::setup;
	isa_ok($config, 'SReview::Config');

	$config->set('dbistring' => 'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB});

	# Prepare the input database
	my $dbh = DBI->connect($config->get('dbistring'));
	$dbh->prepare("INSERT INTO rooms(id, name, altname) VALUES (1, 'room1', 'Room1')")->execute() or die $!;
	$dbh->prepare("INSERT INTO events(id, name) VALUES(1, 'Test event')")->execute() or die $!;
	my $st = $dbh->prepare("INSERT INTO talks(id, room, slug, starttime, endtime, title, description, event, upstreamid) VALUES(1, 1, 'test-talk', '2017-11-10 17:00:00', '2017-11-10 17:00:10', 'Test talk', 'Test talk description', 1, '1') RETURNING nonce") or die $!;
	$st->execute();
	my $row = $st->fetchrow_arrayref;
	my $nonce = $row->[0];
	my $relname = join("/", substr($nonce, 0, 1), substr($nonce, 1, 2), substr($nonce, 3));

	$ENV{SREVIEWTEST_FIXUP_MARKER} = abs_path('t/fixup_marker');
	unlink($ENV{SREVIEWTEST_FIXUP_MARKER});
	$ENV{SREVIEW_CUT_FIXUPS} = encode_json([
		[
			$^X,
			'-e',
			'open my $fh, ">", $ENV{SREVIEWTEST_FIXUP_MARKER} or die $!; print $fh $ARGV[0]; close $fh;'
		],
	]);
	$st = $dbh->prepare("INSERT INTO speakers(name) VALUES(?)");
	$st->execute('Speaker 1');
	$st->execute('Speaker 3');
	$st->execute('Speaker 2');
	$st = $dbh->prepare('INSERT INTO speakers_talks(speaker, talk) VALUES(?, 1)');
	$st->execute(1);
	$st->execute(2);
	$st->execute(3);

	# Detect input files
	run($^X, "-I", $INC[0], "$scriptpath/sreview-detect");

	$st = $dbh->prepare("SELECT * FROM raw_talks");
	$st->execute();
	ok($st->rows == 1, "sreview-detect detects one file");

	$row = $st->fetchrow_hashref();

	my $input = Media::Convert::Asset->new(url => abs_path("t/testvids/bbb.mp4"));
	# perform cut with default normalizer
	run($^X, "-I", $INC[0], "$scriptpath/sreview-cut", $row->{talkid});
	ok(-f $ENV{SREVIEWTEST_FIXUP_MARKER}, "cut fixup ran and created marker file");
	open(my $mfh, "<", $ENV{SREVIEWTEST_FIXUP_MARKER}) or die $!;
	my $marker = do { local $/; <$mfh> };
	close($mfh);
	like($marker, qr/main\.mkv\z/, "cut fixup marker contains the filename passed to the fixup");

	my $coll = SReview::Files::Factory->create("intermediate", $config->get("pubdir"));
	ok($coll->has_file("$relname/0/main.mkv"), "The file is created and added to the collection");
	my $file = $coll->get_file(relname => "$relname/0/main.mkv");
	my $check = Media::Convert::Asset->new(url => $file->filename);
	my $starts = ffprobe_start_times($file->filename);
	ok(exists($starts->{audio}) && exists($starts->{video}), "The generated cut video contains both audio and video");
	my $delta = abs($starts->{audio} - $starts->{video});
	my $tol = $check->video_frame_length;
	cmp_ok($delta, '<=', $tol, 'audio/video start times are close enough after sreview-cut');
	my $length = $check->duration;
	ok($length > 9.75 && $length < 10.25, "The generated cut video is of approximately the right length");
	ok($check->video_codec eq $input->video_codec, "The input video codec is the same as the pre-cut video codec");
	ok($check->audio_codec eq $input->audio_codec, "The input audio codec is the same as the pre-cut audio codec");

	# perform cut with bs1770gain normalizer, if available
	SKIP: {
		skip "bs1770gain tests disabled", 4 if exists($ENV{SREVIEWTEST_SKIP_BS1770GAIN});

		$coll->delete_files(relnames => [$relname]);

		$ENV{SREVIEW_NORMALIZER} = '"bs1770gain"';
		run($^X, "-I", $INC[0], "$scriptpath/sreview-cut", $row->{talkid});

		ok($coll->has_file("$relname/0/main.mkv"), "The file is created and added to the collection");
		$file = $coll->get_file(relname => "$relname/0/main.mkv");
		$check = Media::Convert::Asset->new(url => $file->filename);
		$length = $check->duration;
		ok($length > 9.5 && $length < 10.5, "The generated cut video is of approximately the right length");
		ok($check->video_codec eq $input->video_codec, "The input video codec is the same as the pre-cut video codec");
		ok($check->audio_codec eq $input->audio_codec, "The input audio codec is the same as the pre-cut audio codec");
	}
	run($^X, "-I", $INC[0], "$scriptpath/sreview-previews", $row->{talkid});

	$file = $coll->get_file(relname => "$relname/0/main.mp4");
	$check = Media::Convert::Asset->new(url => $file->filename);
	ok(($length * 0.9 < $check->duration) && ($length * 1.1 > $check->duration), "The preview video is of approximately the right length");

	# perform transcode
	run($^X, "-I", $INC[0], "$scriptpath/sreview-transcode", $row->{talkid});
	my $final = Media::Convert::Asset->new(url => abs_path("t/outputdir/Test event/room1/2017-11-10/test-talk.webm"));
	ok($final->video_codec eq "vp9", "The transcoded video has the right codec");
	ok($final->audio_codec eq "opus", "The transcoded audio has the right codec");

	run($^X, "-I", $INC[0], "$scriptpath/sreview-upload", $row->{talkid});
}

unlink("config.pm");
unlink("t/fixup_marker");
remove_tree("t/inputdir", "t/outputdir", "t/pubdir");
