package SReview::Config::Common;

use SReview::Config;

use strict;
use warnings;
use feature 'state';
use Mojo::JSON qw/decode_json/;

sub get_default_cfile {
	my $dir = $ENV{SREVIEW_WDIR};
	my $write = shift;

	$dir = "." unless defined($dir);
	my $cfile = join('/', $dir, 'config.pm');
	if(!-f $cfile && !exists($ENV{SREVIEW_WDIR})) {
		$cfile = join('/', '', 'etc', 'sreview', 'config.pm');
	}
	return $cfile;
}

sub compute_dbistring {
	if(!exists($ENV{SREVIEW_DBICOMPONENTS})) {
		return undef;
	}
	my @comps = ();
	foreach my $comp(split /\s/, $ENV{SREVIEW_DBICOMPONENTS}) {
		my $COMP = uc $comp;
		push @comps, "$comp=" . $ENV{"SREVIEW_DBI_" . $COMP};
	}
	return "dbi:Pg:" . join(";", @comps);
}

sub compute_accessconfig {
	if(!exists($ENV{SREVIEW_S3_DEFAULT_ACCESSKEY}) || !exists($ENV{SREVIEW_S3_DEFAULT_SECRETKEY})) {
		return undef;
	}
	my $rv = { default => {aws_access_key_id => $ENV{SREVIEW_S3_DEFAULT_ACCESSKEY}, aws_secret_access_key => $ENV{SREVIEW_S3_DEFAULT_SECRETKEY} } };
	if(exists($ENV{SREVIEW_S3_DEFAULT_SECURE})) {
		$rv->{secure} = $ENV{SREVIEW_S3_DEFAULT_SECURE};
	}
	if(exists($ENV{SREVIEW_S3_DEFAULT_HOST})) {
		$rv->{host} = $ENV{SREVIEW_S3_DEFAULT_HOST};
	}
	if(exists($ENV{SREVIEW_S3_EXTRA_CONFIGS})) {
		my $extras = decode_json($ENV{SREVIEW_S3_EXTRA_CONFIGS});
		foreach my $extra(keys %$extras) {
			$rv->{$extra} = $extras->{$extra};
		}
	}
	return $rv;
}

sub setup {
	my $cfile = shift;
	if(!defined($cfile)) {
		$cfile = get_default_cfile();
	}
	state $config;

	return $config if(defined $config);

	$config = SReview::Config->new($cfile);
	# common values
	$config->define('dbistring', 'The DBI connection string used to connect to the database', 'dbi:Pg:dbname=sreview');
	$config->define_computed('dbistring', \&compute_dbistring);
	$config->define('accessmethods', 'The way to access files for each collection. Can be \'direct\' or \'S3\'. For the latter, the \'$s3_access_config\' configuration needs to be set, too', {input => 'direct', output => 'direct', intermediate => 'direct'});
	$config->define('s3_access_config', 'Configuration for accessing S3-compatible buckets. Any option that can be passed to the "new" method of the Net::Amazon::S3 Perl module can be passed to any of the child hashes of the toplevel hash. Uses the same toplevel keys as the "$accessmethods" configuration item, but falls back to "default"', {default => {}});
        $config->define('sftp_access_config', 'Configuration for accessing SFTP hosts. Should be set to a hash keyed to the collection name, with each element being an array of arguments that can be passed to Net::SSH2\'s auth method', {default => {username => "sreview"}});
	$config->define_computed('s3_access_config', \&compute_accessconfig);
	$config->define('api_key', 'The API key, to allow access to the API', undef);
        $config->define('canonical_duration', 'The canonical duration to set for Media::Convert::Asset', undef);

	# Values for sreview-web
	$config->define('event', 'The event to handle by this instance of SReview.');
	$config->define('secret', 'A random secret key, used to encrypt the cookies.', '_INSECURE_DEFAULT_REPLACE_ME_');
	$config->define("vid_prefix", "The URL prefix to be used for video data files", "/video");
	$config->define("anonreviews", "Set to truthy if anonymous reviews should be allowed, or to falsy if not", 0);
	$config->define("preview_exten", "The extension used by previews (webm or mp4). Should be autodetected in the future, but...", "webm");
	$config->define("eventurl_format", "A Mojo::Template that generates an event URL. Used by the /released metadata URL", undef);

	$config->define("adminuser", 'email address for the initial admin user created. Note: if this user is removed and this configuration value continues to exist, then the user will be recreated upon the next database initialization (which might be rather quick).', undef);
	$config->define('adminpw', 'password for the admin user. See under "adminuser" for details.', undef);
	$config->define('review_template', 'The template name to be used for the review page. Can be one of "full" (full editing capabilities) or "confirm" (confirmation only). Defaults to "full", unless the talk was injected, in which case it defaults to "confirm".', undef);
	$config->define('inject_fatal_checks', 'Checks to be run on an uploaded video. When a check fails, the upload is rejected. Same syntax as for inject_transcode_skip_checks.', {});

	$config->define('force_preview_transcode', 'If set to nonzero, forces sreview-previews to transcode the video, even if the input video file is HTML video compatible. Use this if the input video format uses a very large bitrate.', 0);

	# Values for encoder scripts
	$config->define('pubdir', 'The directory on the file system where files served by the webinterface should be stored', '/srv/sreview/web/public');
	$config->define('workdir', 'A directory where encoder jobs can create a subdirectory for temporary files', exists($ENV{TMPDIR}) ? $ENV{TMPDIR} : '/tmp' );
	$config->define('outputdir', 'The base directory under which SReview should place the final released files', '/srv/sreview/output');
	$config->define('output_subdirs', 'An array of fields to be used to create subdirectories under the output directory.', ['event', 'room', 'date']);
	$config->define('script_output', 'The directory to which the output of scripts should be redirected', '/srv/sreview/script-output');
	$config->define('preroll_template', 'An SVG or Synfig template to be used as opening credits. Should have the same nominal dimensions (in pixels) as the video assets. May be a file or an http(s) URL.', undef);
	$config->define('postroll_template', 'An SVG or Synfig template to be used as closing credits. Should have the same nominal dimensions (in pixels) as the video assets. May be a file or an http(s) URL.', undef);
	$config->define('template_format', 'The format that the preroll, postroll, or apology templates are in. One of "svg" or "synfig".', "svg");
	$config->define('postroll', 'A PNG file to be used as closing credits. Will only be used if no postroll_template was defined. Should have the same dimensions as the video assets. Must be a direct file.', undef);
	$config->define('apology_template', 'An SVG template to be used as apology template (shown just after the opening credits when technical issues occurred. Should have the same nominal dimensions (in pixels) as the video assets. May be a file or an http(s) URL.', undef);
	$config->define('output_profiles', 'An array of profiles, one for each encoding, to be used for output encodings', ['webm']);
	$config->define('input_profile', 'The profile that is used for input videos.', undef);
	$config->define('audio_multiplex_mode', 'The way in which the primary and backup audio are multiplexed in the input stream. One of \'stereo\' for the primary in the left channel of the first audio stream and the backup in the right channel, or \'astream\' for the primary in the first audio stream, and the backup in the second audio stream', 'stereo');
	$config->define('normalizer', 'The implementation used to normalize audio. Can be one of: ffmpeg, bs1770gain, or none to disable normalization altogether.', 'ffmpeg');
	$config->define('cut_fixups', 'An array of fixup commands to apply at cut time. Each element is an array containing the command and its arguments; the main video filename will be appended as the final argument.', []);
	$config->define('web_pid_file', 'The PID file for the webinterface, when running under hypnotoad.','/var/run/sreview/sreview-web.pid');
	$config->define('autoreview_detect', 'The script to run when using sreview-autoreview', undef);
	$config->define('video_multi_profiles', 'A hash table of profiles that benefit from multi-pass encoding. AV1 does not support that at the time of writing, and multi-pass is useless for a copy profile. Most other situations do benefit.', {"av1" => 0,"copy" => 0});

	# Values for detection script
	$config->define('inputglob', 'A filename pattern (glob) that tells SReview where to find new files', '/srv/sreview/incoming/*/*/*');
	$config->define('parse_re', 'A regular expression to parse a filename into year, month, day, hour, minute, second, room, and stream', '.*\/(?<room>[^\/]+)(?<stream>(-[^\/-]+)?)\/(?<year>\d{4})-(?<month>\d{2})-(?<day>\d{2})\/(?<hour>\d{2}):(?<minute>\d{2}):(?<second>\d{2})');
	$config->define('file_timezone', 'The timezone that dates and times as parsed from filenames by parse_re are expected to be in. Can be any valid value for the "name" parameter to the DateTime::TimeZone constructor.', 'local');
	$config->define('url_re', 'If set, used with parse_re in an s///g command to produce an input URL', undef);

	# Values for dispatch script
	$config->define('state_actions', 'A hash that tells SReview what to do with a talk when it is in a given state. Mojo::Template is used to transform these.', {
		cutting => 'sreview-cut <%== $talkid %> > <%== $output_dir %>/cut.<%== $talkid %>.out 2> <%== $output_dir %>/cut.<%== $talkid %>.err',
		generating_previews => 'sreview-previews <%== $talkid %> > <%== $output_dir %>/preview.<%== $talkid %>.out 2> <%== $output_dir %>/preview.<%== $talkid %>.err',
		transcoding => 'sreview-transcode <%== $talkid %> > <%== $output_dir %>/trans.<%== $talkid %>.out 2> <%== $output_dir%>/trans.<%== $talkid %>.err',
		uploading => 'sreview-skip <%== $talkid %>',
		notification => 'sreview-skip <%== $talkid %>',
		announcing => 'sreview-skip <%== $talkid %>',
		injecting => 'sreview-inject -t <%== $talkid %>',
		transcribing => 'sreview-transcribe <%== $talkid %>',
	});
	$config->define('dispatch_require_flags', 'An array of talk flags that must be set to true for a talk to be handled by this dispatcher instance.', []);
	$config->define('dispatch_ignore_flags', 'An array of talk flags that, if set to true, will cause a talk to be ignored by this dispatcher instance.', []);
	$config->define('query_limit', 'A maximum number of jobs that should be submitted in a single loop in sreview-dispatch. 0 means no limit.', 1);
	$config->define('published_headers', 'The HTTP headers that indicate that the video is available now. Use _code for the HTTP status code.', undef);
	$config->define('inject_actions', 'A command that tells SReview what to do with a talk that needs to be injected', 'sreview-inject <%== $talkid %> <%== $output_dir %>/inject.<%== $talkid %>.out 2> <%== $output_dir %>/cut.<%== $talkid %>.err');

	# Values for notification script
	$config->define('notify_actions', 'An array of things to do when notifying the readiness of a preview video. Can contain one or more of: email, command.', []);
	$config->define('announce_actions', 'An array of things to do when announcing the completion of a transcode. Can contain one or more of: email, command.', []);
	$config->define('notify_final_actions', 'An array of things to do when notifying the readiness of a final review. Can contain one or more of: email, command', []);
	$config->define('email_template', 'A filename of a Mojo::Template template to process, returning the email body used in notifications or announcements. Can be overridden by announce_email_template or notify_email_template.', undef);
	$config->define('notify_email_template', 'A filename of a Mojo::Template template to process, returning the email body used in notifications. Required, but defaults to the value of email_template', undef);
	$config->define('announce_email_template', 'A filename of a Mojo::Template template to process, returning the email body used in announcements. Required, but defaults to the value of email_template', undef);
	$config->define('notify_final_email_template', 'A filename of a Mojo::Template template to process, returning the email body used in final review notifications. Required, but defaults to the value of email_template', undef);
	$config->define('email_from', 'The data for the From: header in any email. Required if notify_actions, notify_final_actions, or announce_actions includes email.', undef);
	$config->define('notify_email_subject', 'The data for the Subject: header in the email. Required if notify_actions includes email.', undef);
	$config->define('announce_email_subject', 'The data for the Subject: header in the email. Required if announce_actions includes email.', undef);
	$config->define('notify_final_email_subject', 'The data for the Subject: header in the email. Required if notify_final_actions includes email.', undef);
	$config->define('urlbase', 'The URL on which SReview runs. Note that this is used by sreview-notify to generate URLs, not by sreview-web.', '');
	$config->define('notify_commands', 'An array of commands to run to perform notifications. Each component is passed through Mojo::Template before processing. To avoid quoting issues, it is a two-dimensional array, so that no shell will be called to run this.', [['echo', '<%== $title %>', 'is', 'available', 'at', '<%== $url %>']]);
	$config->define('announce_commands', 'An array of commands to run to perform announcements. Each component is passed through Mojo::Template before processing. To avoid quoting issues, it is a two-dimensional array, so that no shell will be called to run this.', [['echo', '<%== $title %>', 'is', 'available', 'at', '<%== $url %>']]);
	$config->define('notify_final_commands', 'An array of commands to run to perform final review notification. Each component is passed through Mojo::Template before processing. To avoid quoting issues, it is a two-dimensional array, so that no shell will be called to run this.', [['echo', '<%== $title %>', 'is', 'available', 'for', 'final', 'review', 'at', '<%== $url %>']]);

	# Values for upload script
	$config->define('upload_actions', 'An array of commands to run on each file to be uploaded. Each component is passed through Mojo::Template before processing. To avoid quoting issues, it is a two-dimensional array, so that no shell will be called to run this.', [['echo', '<%== $file %>', 'ready for upload']]);
	$config->define('remove_actions', 'An array of commands to run on each file to be removed, when final review determines that the file needs to be reprocessed. Same format as upload_actions', [['echo', '<%== $file %>', 'ready for removal']]);
        $config->define('sync_extensions', 'An array of extensions of files to sync');
	$config->define('sync_actions', 'An array of commands to run on each file to be synced. Each component is passed through Mojo::Template before processing. To avoid quoting issues, it is a two-dimensional array, so that no shell will be called to run this.', [['echo', '<%== $file %>', 'ready for sync']]);
	$config->define('cleanup', 'Whether to remove files after they have been published. Possible values: "all" (removes all files), "previews" (removes the output of sreview-cut, but not that of sreview-transcode), and "output" (removes the output of sreview-transcode, but not the output of sreview-cut). Other values will not remove files', 'none');

	# for sreview-copy
	$config->define('extra_collections', 'A hash of extra collection basenames. Can be used by sreview-copy.', undef);

	# for sreview-keys
	$config->define('authkeyfile', 'The authorized_keys file that sreview-keys should manage. If set to undef, the default authorized_keys file will be used.');

	# for extending profiles
	$config->define('extra_profiles', 'Any extra custom profiles you want to use. This hash should have two keys: the "parent" should be a name of a profile to subclass from, and the "settings" should contain a hash reference with attributes for the new profile to set', {});

	# for sreview-import
	$config->define('schedule_format', 'The format in which the schedule is set. Must be implemented as a child class of SReview::Schedule::Base', 'penta');
	$config->define('schedule_options', 'The options to pass to the schedule parser as specified through schedule_format. See the documentation of your chosen parser for details.', {});

	# for sreview-inject
	$config->define('inject_transcode_skip_checks', "Minimums and maximums, or exact values, of video assets that cause sreview-inject to skip the transcode if they match the video asset", {});
	$config->define('inject_collection', "The collection into which uploads are stored. One of: input, pub, or any of the keys of the 'extra_collections' hash", "input");

	# for sreview-transcode
	$config->define("video_license", "the license of the output videos. If defined, will be set as a \"license\" tag on the media container, provided the container supports that.", undef);
        $config->define("metadata_templates", 'A hash of SReview::Template templates to set metadata on output files. Sets the $talk and $config variables.', { title => '<%= $talk->title %>\\', event => '<%= $config->get("event") %>\\', speakers => '<%= $talk->speakers %>\\', track => '<%= $talk->track_name %>\\', 'date' => '<%= $talk->date %>\\', 'recording_location' => '<%= $talk->room %>\\', 'synopsis' => '<%= $talk->description %>\\', 'subtitle' => '<%= $talk->subtitle %>\\', 'license' => '<%= $config->get("video_license") %>\\', url => '<%= $talk->eventurl %>\\' });

	# for tuning command stuff
	$config->define('command_tune', 'Some commands change incompatibly from one version to the next. This option exists to deal with such incompatibilities', {});

	# for final review
	$config->define('finalhosts', 'A list of hosts that may host videos for final review, to be added to Content-Security-Policy "media-src" directive.', undef);
	$config->define('output_video_url_format', 'A Mojo::Template that will produce the URLs for the produced videos. Can use the $talk variable for the SReview::Talk, and the $exten variable for the extension of the current video profile');

	# for transcription
	$config->define('transcribe_command', 'A Mojo::Template for the command to transcribe a video.', undef);
        $config->define('transcribe_source_extension', 'The extension of the video to be used when running sreview-transcribe', 'webm');

	return $config;
}

1;
