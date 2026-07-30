package SReview::Talk;

use Moose;

use Media::Convert::Asset;
use Media::Convert::Asset::ProfileFactory;
use Mojo::Pg;
use Mojo::Template;
use Mojo::JSON qw/encode_json decode_json/;
use SReview::Config::Common;
use SReview::Talk::State;
use SReview::Talk::Progress;
use SReview::Template;
use DateTime::Format::Pg;

use feature "say";

my $config = SReview::Config::Common::setup;
my $pg = Mojo::Pg->new->dsn($config->get('dbistring')) or die "Cannot connect to database!";

=head1 NAME

SReview::Talk - Database abstraction for talks in the SReview database

=head1 SYNOPSIS

  use SReview::Talk;

  my $talk = SReview::Talk->new(talkid => 1);
  print $talk->nonce;
  my $nonce = $talk->nonce;
  my $talk_alt = SReview::Talk->by_nonce($nonce);
  print $talk_alt->talkid; # 1

  $talk->add_correction(length_adj => 1);
  $talk->done_correcting;

=head1 DESCRIPTION

SReview::Talk provides a (Moose-based) object-oriented interface to the
data related to a talk that is stored in the SReview database. Although
it is not yet used everywhere, the intention is for it to eventually
replace all the direct PostgreSQL calls.

=head1 PROPERTIES

=head2 talkid

The unique ID of the talk. Required attribute at construction time (but
see the C<by_nonce> method, below). Is used to look up the relevant data
in the database.

=cut

has 'talkid' => (
	required => 1,
	is => 'ro',
        trigger => sub {
                my $self = shift;
                my $val = shift;
                my $st = $pg->db->dbh->prepare("SELECT count(*) FROM talks WHERE id = ?");
                $st->execute($val);
                die "Talk does not exist.\n" unless $st->rows == 1;
        },
);

has 'upstreamid' => (
	is => 'ro',
	isa => 'Str',
	builder => '_probe_upstreamid',
	lazy => 1,
);

sub _probe_upstreamid {
	return shift->_get_pathinfo->{raw}{upstreamid}
}

=head2 pathinfo

Helper property to look up information from the database. Should not be
used directly.

=cut

has 'pathinfo' => (
	lazy => 1,
	is => 'bare',
	builder => '_load_pathinfo',
	reader => '_get_pathinfo',
);

sub _load_pathinfo {
	my $self = shift;

	my $pathinfo = {};

	my $eventdata = $pg->db->dbh->prepare("SELECT events.id AS eventid, events.name AS event, events.outputdir AS event_output, rooms.name AS room, rooms.outputname AS room_output, rooms.id AS room_id, talks.starttime, talks.starttime::date AS date, to_char(starttime, 'DD Month yyyy at HH24:MI') AS readable_date, to_char(talks.starttime, 'yyyy') AS year, talks.endtime, talks.slug, talks.title, talks.subtitle, talks.state, talks.progress, talks.nonce, talks.apologynote, talks.upstreamid, talks.description, tracks.name AS track_name, talks.extra_data FROM talks JOIN events ON talks.event = events.id JOIN rooms ON rooms.id = talks.room LEFT JOIN tracks ON tracks.id = talks.track WHERE talks.id = ?");
	$eventdata->execute($self->talkid) or die $!;
	my $row = $eventdata->fetchrow_hashref();

	my @elements = ($config->get('outputdir'));
        ELEMENT:
	foreach my $element(@{$config->get('output_subdirs')}) {
                if(!defined($row->{$element})) {
                        say "E: Value for $element not defined in the database for talk with ID " . $self->talkid . "\nSkipping that element in the output directory";
                        next ELEMENT;
                }
		push @elements, $row->{$element};
	}
	$pathinfo->{"finaldir"} = join('/', @elements);

        $pathinfo->{"slug"} = $row->{"slug"};

	$pathinfo->{"raw"} = $row;

	return $pathinfo;
}

=head2 flags

Flags set on this talk. Setter: C<set_flag>; getter: C<get_flag>. Flags can be deleted with C<delete_flag>.

=cut

has 'flags' => (
	is => 'rw',
	traits => [ 'Hash' ],
	isa => 'HashRef[Bool]',
	builder => '_probe_flags',
	lazy => 1,
	predicate => '_has_flags',
	handles => {
		set_flag => 'set',
		get_flag => 'get',
		delete_flag => 'delete',
	},
);

sub _probe_flags {
	my $self = shift;
	my $st = $pg->db->dbh->prepare("SELECT flags FROM talks WHERE id = ?");
	$st->execute($self->talkid);
	my $row = $st->fetchrow_arrayref;
	if(defined($row->[0])) {
		return decode_json($row->[0]);
	}
	return {};
}

has 'active_stream' => (
	is => 'rw',
	builder => '_probe_stream',
	lazy => 1,
	predicate => 'has_stream',
);

sub _probe_stream {
	my $self = shift;
	my $st = $pg->db->dbh->prepare("SELECT active_stream FROM talks WHERE id = ?");
	$st->execute($self->talkid);
	my $row = $st->fetchrow_arrayref;
	return $row->[0];
}

=head2 apology

The apology note, if any. Predicate: C<has_apology>.

=cut

has 'apology' => (
        lazy => 1,
        is => 'rw',
        builder => '_load_apology',
        clearer => 'clear_apology',
        predicate => 'has_apology',
);

sub _load_apology {
        return shift->_get_pathinfo->{raw}{apologynote};
}

=head2 comment

The comments that the user entered in the "other brokenness" field.
Predicate: C<has_comment>; clearer: C<clear_comment>.

=cut

has 'comment' => (
        lazy => 1,
        is => 'rw',
        builder => '_load_comment',
        clearer => 'clear_comment',
        predicate => 'has_comment',
);

sub _load_comment {
        my $self = shift;
        my $st = $pg->db->dbh->prepare("WITH orderedlog(talk, comment, logdate) AS (SELECT talk, comment, logdate FROM commentlog ORDER BY logdate DESC) SELECT talk, string_agg(logdate || E'\n' || comment, E'\n\n') AS comments FROM orderedlog WHERE talk = ? GROUP BY talk");
        $st->execute($self->talkid);
        my $row = $st->fetchrow_hashref;
        return $row->{comments};
}

=head2 first_comment

The most recent comment entered in the "other brokenness" field.

=cut

has 'first_comment' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_first_comment',
	clearer => 'clear_first_comment',
	predicate => 'has_first_comment',
);

sub _load_first_comment {
	my $self = shift;

	my $st = $pg->db->dbh->prepare("WITH orderedlog(talk, comment) AS (SELECT talk, comment FROM commentlog ORDER BY logdate DESC) SELECT talk, comment FROM orderedlog WHERE talk = ? LIMIT 1");
	$st->execute($self->talkid);
	my $row = $st->fetchrow_hashref;
	return $row->{comment};
}

=head2 corrected_times

The start- and endtime of the talk, with corrections (if any) applied.

=cut

has 'corrected_times' => (
        lazy => 1,
        is => 'ro',
        builder => '_load_corrected_times',
);

sub _load_corrected_times {
        my $self = shift;

        my $times = {};

        my $st = $pg->db->dbh->prepare("SELECT starttime, to_char(starttime, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS isostart, endtime, to_char(endtime, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS isoend from talks WHERE id = ?");

        $st->execute($self->talkid);

        die "talk lost" unless $st->rows > 0;

        my $row = $st->fetchrow_hashref();
        $times->{start} = $row->{starttime};
        $times->{end} = $row->{endtime};
        $times->{start_iso} = $row->{isostart};
        $times->{end_iso} = $row->{isoend};

        $st = $pg->db->dbh->prepare("SELECT coalesce(talks.starttime + (corrections.property_value || ' seconds')::interval, talks.starttime) AS corrected_time, to_char(coalesce(talks.starttime + (corrections.property_value || ' seconds')::interval, talks.starttime), 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS isotime  FROM talks LEFT JOIN corrections ON talks.id = corrections.talk LEFT JOIN properties ON properties.id = corrections.property WHERE talks.id = ? AND properties.name = 'offset_start'");
        $st->execute($self->talkid);
        if($st->rows > 0) {
                $row = $st->fetchrow_hashref();
                $times->{start} = $row->{corrected_time};
                $times->{start_iso} = $row->{isotime};
        }
        $st = $pg->db->dbh->prepare("SELECT corrected_time, to_char(corrected_time, 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS isotime FROM (select ?::timestamptz + (talks.endtime - talks.starttime) + (coalesce(corrections.property_value, '0') || ' seconds')::interval AS corrected_time FROM talks LEFT JOIN corrections ON talks.id = corrections.talk LEFT JOIN properties ON properties.id = corrections.property WHERE talks.id = ? AND properties.name = 'length_adj') AS sq");
        $st->execute($times->{start}, $self->talkid);
        if($st->rows > 0) {
                $row = $st->fetchrow_hashref();
                $times->{end} = $row->{corrected_time};
                $times->{end_iso} = $row->{isotime};
        }
        return $times;
}

=head2 nonce

The talk's unique hex string, used to look it up for review.

=cut

has 'nonce' => (
        is => 'rw',
        builder => '_load_nonce',
        lazy => 1,
);

sub _load_nonce {
        return shift->_get_pathinfo->{raw}{nonce};
}

=head2 date

The date on which the talk happened

=cut

has 'date' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_date',
);

sub _load_date {
	return shift->_get_pathinfo->{raw}{date};
}

=head2 readable_date

The date on which the talk happened, in a (somewhat) more human-readable
format than the C<date> property.

=cut

has 'readable_date' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_readable_date',
);

sub _load_readable_date {
	return shift->_get_pathinfo->{raw}{readable_date};
}

=head2 eventname

The name of the event of which this talk is part

=cut

has 'eventname' => (
	lazy => 1,
	is => 'ro',
	builder => '_load_eventname',
);

sub _load_eventname {
	my $self = shift;
	return $self->_get_pathinfo->{raw}{event};
}

=head2 event_output

The name of the event as used in output directories, if any.

=cut

has 'event_output' => (
	lazy => 1,
	is => 'ro',
	builder => '_load_event_output',
);

sub _load_event_output {
	my $self = shift;

	my $rv = $self->_get_pathinfo->{raw}{event_output};
	if(!defined($rv) || length($rv) == 0) {
		$rv = $self->_get_pathinfo->{raw}{event};
		$rv =~ s/[^a-zA-Z0-9]/-/g;
	}
	return $rv;
}

=head2 progress

The current progress value of the talk, as an L<SReview::Talk::Progress>

=cut

has 'progress' => (
	lazy => 1,
	is => 'rw',
	isa => 'SReview::Talk::Progress',
	builder => '_load_progress',
);

sub _load_progress {
	my $self = shift;
	return SReview::Talk::Progress->new($self->_get_pathinfo->{raw}{progress});
}

=head2 state

The current state of the talk, as an L<SReview::Talk::State>

=cut

has 'state' => (
	lazy => 1,
	is => 'rw',
	isa => 'SReview::Talk::State',
	builder => '_load_state',
);

sub _load_state {
	my $self = shift;
	return SReview::Talk::State->new($self->_get_pathinfo->{raw}{state});
}

=head2 title

The title of the talk

=cut

has 'title' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_title',
);

sub _load_title {
	my $self = shift;
	return $self->_get_pathinfo->{raw}{title};
}

=head2 subtitle

The subtitle of the talk

=cut

has 'subtitle' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_subtitle',
);

sub _load_subtitle {
	my $self = shift;
	return $self->_get_pathinfo->{raw}{subtitle};
}

=head2 workdir

The working directory where the files for this talk should be stored

=cut

has 'workdir' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_workdir',
);

sub _load_workdir {
	my $self = shift;
	return join('/', $config->get("pubdir"), $self->relative_name);
}

=head2 relative_name

The relative path- and file name under the output directory for this
talk.

=cut

has 'relative_name' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_relative_name',
);

sub _load_relative_name {
	my $self = shift;
	my $n = $self->nonce;
	my $serial = $self->has_correction("serial") ? ${$self->corrections}{serial} : 0;
	if($self->state eq "broken" && $serial > 0) {
		$serial -= 1;
	}
	return join('/', substr($n, 0, 1), substr($n, 1, 2), substr($n, 3), $serial);
}

=head2 outname

The output name for this talk

=cut

has 'outname' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_outname',
);

sub _load_outname {
	my $self = shift;
	return join('/', $self->workdir, $self->_get_pathinfo->{"slug"});
}

=head2 finaldir

The directory in which things are stored

=cut

has 'finaldir' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_finaldir',
);

sub _load_finaldir {
	my $self = shift;
	return $self->_get_pathinfo->{"finaldir"};
}

=head2 slug

A short, safe representation of the talk; used for filenames.

=cut

has 'slug' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_slug',
);

sub _load_slug {
	my $self = shift;
	return $self->_get_pathinfo->{"slug"};
}

=head2 corrections

The corrections that are set on this talk.

Supports:

=over

=item has_correction

check whether a correction exists (by name)

=item set_correction

Overwrite a correction with a new value

=item clear_correction

Remove a correction from the set of corrections

=item correction_pairs

Get a key/value list of corrections

=back

=cut

has 'corrections' => (
        traits => ['Hash'],
        isa => 'HashRef[Str]',
	lazy => 1,
	is => 'rw',
	builder => '_load_corrections',
	clearer => '_clear_corrections',
        handles => {
                has_correction => 'exists',
                set_correction => 'set',
                clear_correction => 'delete',
                correction_pairs => 'kv',
        },
);

sub _load_corrections {
	my $self = shift;

	my $corrections_data = $pg->db->dbh->prepare("SELECT corrections.talk, properties.name AS property, corrections.property_value FROM corrections LEFT JOIN properties ON corrections.property = properties.id WHERE talk = ?");
	$corrections_data->execute($self->talkid);

	my %corrections;

	while(my $row = $corrections_data->fetchrow_hashref()) {
		my $name = $row->{property};
		my $val = $row->{property_value};
		$corrections{$name} = $val;
	}

	foreach my $prop ("offset_start", "length_adj", "offset_audio", "audio_channel") {
		if(!exists($corrections{$prop})) {
			$corrections{$prop} = 0;
		}
	}

	return \%corrections;
}

=head2 video_fragments

Gets a list of hashes with data on the fragments of video files that are
necessary to build the talk, given the schedule and the current
corrections.

Each hash contains:

=over 

=item talkid

The talk ID for fragments that are part of the main video; -1 for
fragments that are part of the pre video; and -2 for fragments that are
part of the post video.

=item rawid

The unique ID of the raw file

=item raw_filename

The filename of the raw file

=item fragment_start

The offset into the raw file where the interesting content begins.

=item raw_length

The length of the entire video (should be the same for each fragment)

=item raw_length_corrected

The length of the interesting content in I<this> raw file

=back

=cut

has 'video_fragments' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_video_fragments',
);

sub _load_video_fragments {
	my $self = shift;
	my $corrections = $self->corrections;

	my $talk_data = $pg->db->dbh->prepare("SELECT talkid, rawid, raw_filename, extract(epoch from fragment_start) AS fragment_start, extract(epoch from raw_length) as raw_length, extract(epoch from raw_length_corrected) as raw_length_corrected FROM adjusted_raw_talks(?, make_interval(secs :=?::numeric), make_interval(secs := ?::numeric)) ORDER BY talk_start, raw_start");
	$talk_data->execute($self->talkid, $corrections->{"offset_start"}, $corrections->{"length_adj"});

	my $rows = [];
	while(my $row = $talk_data->fetchrow_hashref()) {
		push @$rows, $row;
	}

	return $rows;
}

=head2 avs_video_fragments

The same values as the video_fragments attribute, but with every length
extended as needed for A/V sync operations.

=cut

has 'avs_video_fragments' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_avs_video_fragments',
);

sub _load_avs_video_fragments {
	my $self = shift;
	my $corrections = $self->corrections;

	if($corrections->{offset_audio} == 0) {
		return $self->video_fragments;
	}
	my $talk_data = $pg->db->dbh->prepare("SELECT talkid, rawid, raw_filename, extract(epoch from fragment_start) as fragment_start, extract(epoch from raw_length) as raw_length, extract(epoch from raw_length_corrected) as raw_length_corrected from adjusted_raw_talks(?, make_interval(secs :=?::numeric), make_interval(secs := ?::numeric), make_interval(secs :=abs(?::numeric))) order by talk_start, raw_start");
	$talk_data->execute($self->talkid, $corrections->{"offset_start"}, $corrections->{"length_adj"}, $corrections->{"offset_audio"});

	my $rows;
	while(my $row = $talk_data->fetchrow_hashref()) {
		push @$rows, $row;
	}

	return $rows;
}

=head2 speakers

The names of the speakers as a single string, in the format 'Firstname
Lastname, Firstname Lastname, ..., Firstname Lastname and Firstname
Lastname'

=cut

has 'speakers' => (
	lazy => 1,
	is => 'ro',
	builder => '_load_speakers',
);

sub _load_speakers {
	my $self = shift;

	my $spk = $pg->db->dbh->prepare("SELECT speakerlist(?)");

	$spk->execute($self->talkid);

	my $row = $spk->fetchrow_arrayref;

	return $row->[0];
}

=head2 speakerlist

An array of speaker names

=cut

has 'speakerlist' => (
	lazy => 1,
	is => 'ro',
	isa => 'ArrayRef[Str]',
	builder => '_load_speakerlist',
);

sub _load_speakerlist {
	my $self = shift;

	my $query = $pg->db->dbh->prepare("SELECT speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = ? ORDER BY speakers.name");

	$query->execute($self->talkid);

	my $rv = [];

	while(my $talk = $query->fetchrow_arrayref) {
		push @$rv, $talk->[0];
	}

	return $rv;
}

=head2 room

The room in which the talk happened/will happen

=cut

has 'room' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_room',
);

sub _load_room {
	return shift->_get_pathinfo->{raw}{room};
}

=head2 roomid

The unique ID of the room

=cut

has 'roomid' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_roomid',
);

sub _load_roomid {
	return shift->_get_pathinfo->{raw}{room_id}
}

=head2 eventurl

The URL for the talk on the event's website. Only contains data if
C<$eventurl_format> is set in the config file; if it doesn't, returns
the empty string.

=cut

has 'eventurl' => (
	lazy => 1,
	is => 'rw',
	builder => '_load_eventurl',
);

sub _load_eventurl {
	my $self = shift;
	my $mt = Mojo::Template->new;
	if(defined($config->get('eventurl_format'))) {
		my $rv = $mt->vars(1)->render($config->get('eventurl_format'), {
			slug => $self->slug,
			room => $self->room,
			date => $self->date,
			event => $self->eventname,
			event_output => $self->event_output,
			talk => $self,
			room_output => $self->_get_pathinfo->{raw}{room_output} // $self->_get_pathinfo->{raw}{room},
			year => $self->_get_pathinfo->{raw}{year}});
		chomp $rv;
		return $rv;
	}
	return "";
}

=head2 output_video_urls

An array of URLs for the output videos, as they will be published. Used by final review.

=cut

has 'output_video_urls' => (
	lazy => 1,
	is => 'ro',
	isa => 'ArrayRef[HashRef[Str]]',
	builder => '_load_output_urls',
);

sub _load_output_urls {
	my $self = shift;
	my $mt = Mojo::Template->new;
	my $form = $config->get("output_video_url_format");
	my $rv = [];
	if(defined($form)) {
		my $vid = Media::Convert::Asset->new(url => "");
		foreach my $prof(@{$config->get("output_profiles")}) {
			my $item = {prof => $prof};
			if($prof eq "copy") {
				$prof = $config->get("input_profile");
			}
			my $exten = Media::Convert::Asset::ProfileFactory->create($prof, $vid, $config->get('extra_profiles'))->exten;
			my $url = $mt->vars(1)->render($form, {
				talk => $self,
				year => $self->_get_pathinfo->{raw}{year},
				exten => $exten
			});
			chomp $url;
			$item->{url} = $url;
			push @$rv, $item;
		}
	}
	return $rv;
}

=head2 preview_exten

The file extension of the preview file (.webm or .mp4)

=cut

has 'preview_exten' => (
	lazy => 1,
	is => 'ro',
	builder => '_load_preview_exten',
);

# TODO: autodetect this, rather than hardcoding it
sub _load_preview_exten {
	return $config->get('preview_exten');
}

=head2 scheduled_length

The length of the talk, as scheduled

=cut

has 'scheduled_length' => (
	is => "ro",
	lazy => 1,
	builder => "_load_scheduled_length",
);

sub _load_scheduled_length {
	my $self = shift;
	my $start = DateTime::Format::Pg->parse_datetime($self->_get_pathinfo->{raw}{starttime});
	my $end = DateTime::Format::Pg->parse_datetime($self->_get_pathinfo->{raw}{endtime});
	return $end->epoch - $start->epoch;
}

=head2 description

The talk's description

=cut

has 'description' => (
        is => 'ro',
        lazy => 1,
        builder => '_load_description',
);

sub _load_description {
        my $self = shift;
        return $self->_get_pathinfo->{raw}{description};
}

=head2 track_name

The name of the track this talk is in, if any

=cut

has 'track_name' => (
        is => 'ro',
        lazy => 1,
        builder => '_load_track_name',
);

sub _load_track_name {
        return shift->_get_pathinfo->{raw}{track_name};
}

=head2 extra_data

The contents of the "extra_data" field, as imported by L<sreview-import>

=cut

has 'extra_data' => (
		is => 'ro',
		isa => 'Maybe[HashRef]',
		lazy => 1,
		builder => '_load_extra_data',
);

sub _load_extra_data {
	my $raw = shift->_get_pathinfo->{raw}{extra_data};
	return defined($raw) ? decode_json($raw) : undef;
}

=head1 METHODS

=head2 by_nonce

Looks up (and returns) the talk by nonce, rather than by talk ID

=cut

sub by_nonce {
	my $klass = shift;
	my $nonce = shift;

	my $st = $pg->db->dbh->prepare("SELECT * FROM talks WHERE nonce = ?");
	$st->execute($nonce);
	die "Talk does not exist.\n" unless $st->rows == 1;
	my $row = $st->fetchrow_arrayref;
	my $rv = SReview::Talk->new(talkid => $row->[0], nonce => $nonce);
	return $rv;
}

=head2 by_slug

Looks up (and returns) the talk by slug, rather than by talk ID

=cut

sub by_slug {
	my $klass = shift;
	my $slug = shift;
	my $event = shift;

	my $st;
	if(defined($event)) {
		$st = $pg->db->dbh->prepare("SELECT * FROM talks WHERE slug = ? AND event = ?");
		$st->execute($slug, $event);
	} else {
		$st = $pg->db->dbh->prepare("SELECT * FROM talks WHERE slug = ?");
		$st->execute($slug);
	}
	die "Talk does not exist (or the slug is not unique in the database).\n" unless $st->rows == 1;
	my $row = $st->fetchrow_arrayref;
	my $rv = SReview::Talk->new(talkid => $row->[0], slug => $slug);
	return $rv;
}

=head2 add_correction

Interpret a correction as a number, and add the passed parameter to it.
The new value of the correction will be the sum of the parameter and the
old correction.

=cut

sub add_correction {
        my $self = shift;
        my $corrname = shift;
        my $value = shift;

        if($self->has_correction($corrname)) {
                $value = $self->corrections->{$corrname} + $value;
        }
        $self->set_correction($corrname, $value);
}

=head2 done_correcting

Commit the created corrections to the database. Also commits other
things, like the comment and the flags.

=cut

sub done_correcting {
        my $self = shift;

        my $db = $pg->db->dbh;
        my $st = $db->prepare("INSERT INTO corrections(talk, property, property_value) VALUES (?, (SELECT id FROM properties WHERE name = ?), ?)");

        $self->add_correction(serial => 1);
        my $corrs = $self->corrections;
        my $start = $corrs->{offset_start};
        my $end = $corrs->{offset_end};
        $start = 0 unless defined $start;
        $end = 0 unless defined $end;
        $self->set_correction(length_adj => $end - $start);
        foreach my $pair($self->correction_pairs) {
                $st->execute($self->talkid, $pair->[0], $pair->[1]);
        }
        if($self->has_comment) {
                $db->prepare("INSERT INTO commentlog(comment, talk, state) VALUES (?, ?, ?)")->execute($self->comment, $self->talkid, $self->state);
        }
	if($self->has_apology) {
		$db->prepare("UPDATE talks SET apologynote=? WHERE id = ?")->execute($self->apology, $self->talkid);
	}
	if($self->_has_flags) {
		$db->prepare("UPDATE talks SET flags=? WHERE id = ?")->execute(encode_json($self->flags), $self->talkid);
	}
	if($self->has_stream) {
		$db->prepare("UPDATE talks SET active_stream=? WHERE id = ?")->execute($self->active_stream, $self->talkid);
	}
}

=head2 set_state

Override the state of the talk to a new state, ignoring the state
transitions. Note, does not update the object, so this should be done
just before destroying it.

=cut

sub set_state {
        my $self = shift;
        my $newstate = shift;
	my $progress = shift;

	$progress = 'waiting' unless defined($progress);
	my $dbh = $pg->db->dbh;

        my $st = $dbh->prepare("UPDATE talks SET state=?, progress=? WHERE id=?") or die $dbh->errstr;
        $st->execute($newstate, $progress, $self->talkid) or die $dbh->errstr;
}

=head2 state_done

Set the progress to "done" in the given state. Does nothing if the talk
has since moved to another state.

=cut

sub state_done {
        my $self = shift;
        my $state = shift;

        my $st = $pg->db->dbh->prepare("UPDATE talks SET progress='done' WHERE state = ? AND id = ?");
        $st->execute($state, $self->talkid);
}

=head2 reset_corrections

Clear all corrections, except the serial one. Used when a user requests
that the talk be reset to default.

=cut

sub reset_corrections {
        my $self = shift;

        $self->add_correction(serial => 1);
        $pg->db->dbh->prepare("DELETE FROM corrections WHERE talk = ? AND property NOT IN (SELECT id FROM properties WHERE name = 'serial')")->execute($self->talkid) or die $!;
}

=head2 get_metadata

Returns a hash that can be passed to L<Media::Convert::Asset/metadata>. See the
documentation on that property for more details.

=cut

sub get_metadata {
        my $self = shift;
        my $rv = {};

        my $metadata_config = $config->get('metadata_templates');
        my $templ = SReview::Template->new(talk => $self, vars => {config => $config});
        foreach my $metadata(keys %$metadata_config) {
                eval {
                        $rv->{$metadata} = $templ->string($metadata_config->{$metadata});
                };
                if($@) {
                        delete $rv->{$metadata};
                }
                elsif(length($rv->{$metadata}) == 0) {
                        delete $rv->{$metadata};
                }
        }

        return $rv;
}

no Moose;

1;
