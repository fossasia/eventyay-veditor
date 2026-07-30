package SReview::Schedule::Base::Talk;

use Moose;
use Mojo::Util 'slugify';
use DateTime;
use DateTime::Duration;

has 'event_object' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Event',
	weak_ref => 1,
	required => 1,
);

has 'room' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Room',
	lazy => 1,
	builder => '_load_room',
);

sub _load_room {
	my $self = shift;
	return $self->event_object->root_object->room_type->new(event_object => $self->event_object);
}

has 'slug' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_slug',
);

sub _load_slug {
	my $self = shift;
	return substr(slugify($self->title), 0, 40);
}

has 'starttime' => (
	is => 'ro',
	isa => 'DateTime',
	lazy => 1,
	builder => '_load_starttime',
);

sub _load_starttime {
	return DateTime->now;
}

has 'endtime' => (
	is => 'ro',
	isa => 'DateTime',
	lazy => 1,
	builder => '_load_endtime',
);

sub _load_endtime {
	my $self = shift;
	my $start = $self->starttime;
	my $tz = $start->time_zone;
	$start->set_time_zone('UTC');
	my $end = $self->starttime + $self->length;
	$start->set_time_zone($tz);
	$end->set_time_zone($tz);
	return $end;
}

has 'length' => (
	is => 'ro',
	isa => 'DateTime::Duration',
	lazy => 1,
	builder => '_load_length',
);

sub _load_length {
	return DateTime::Duration->new(hours => 1);
}

has 'title' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_title',
);

sub _load_title {
	return "";
}

has 'upstreamid' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_upstreamid',
);

sub _load_upstreamid {
	return shift->slug;
}

has 'subtitle' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_subtitle',
);

sub _load_subtitle {
	return undef;
}

has 'track' => (
	is => 'ro',
	isa => 'Maybe[SReview::Schedule::Base::Track]',
	lazy => 1,
	builder => '_load_track',
);

sub _load_track {
	return undef;
}

has 'description' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_description',
);

sub _load_description {
	return undef;
}

has 'flags' => (
	is => 'ro',
	isa => 'Maybe[HashRef[Bool]]',
	lazy => 1,
	builder => '_load_flags',
);

sub _load_flags {
	return undef;
}

has 'speakers' => (
	is => 'ro',
	isa => 'Maybe[ArrayRef[SReview::Schedule::Base::Speaker]]',
	lazy => 1,
	builder => '_load_speakers',
);

sub _load_speakers {
	return [];
}

has 'filtered' => (
	is => 'ro',
	isa => 'Bool',
	lazy => 1,
	builder => '_load_filtered',
);

sub _load_filtered {
	return 0;
}

has 'extra_data' => (
	is => 'ro',
	isa => 'Maybe[HashRef]',
	lazy => 1,
	builder => '_load_extra_data',
);

sub _load_extra_data {
	return undef;
}

no Moose;

1;

__END__

=head1 NAME

SReview::Schedule::Base::Talk

=head1 DESCRIPTION

A class to hold a talk.

=head1 ATTRIBUTES

=over

=item event_object

The C<SReview::Schedule::Base::Event> (or subclass) object that this
talk is associated with. Required at construction time; weak reference.

=item room

The room object associated with this talk.

The default implementation of C<_load_room> just calls
C</event_object->root_object->room_type> to get the room type, then
creates a new object of that type with the C<event_object> parameter set
to the value of C</event_object>

=item slug

The slug (representation of the name in a syntax that doesn't make a URL
look fugly) of the talk.

The default implementation of C<_load_slug> takes the first 40
characters of the output of the L<Mojo::Util::slugify> method on the
C<title> attribute.

=item starttime

The time at which the talk is scheduled to start, as a L<DateTime>.

The default implementation of C<_load_starttime> returns the current
time, which is probably wrong.

=item endtime

The time at which the talk is scheduled to end, as a L<DateTime>.

The default implementation of C<_load_endtime> takes L</starttime> and
adds the value of L</length>. This allows schedule parsers for formats
that provide a start time and length but no end time to only supply a
method to get the length of the talk and rely on this default
implementation to calculate the expected end time.

=item length

The length of the talk, as a L<DateTime::Duration>. Not required if a
non-default implementation of C<_load_endtime> is provided, but defaults
to a value of one hour regardless.

=item title

The title of the talk.

The default C<_load_title> implementation returns the empty string. This
is almost certainly incorrect.

=item upstreamid

A unique, unchanging ID used by the schedule for this talk. If not set,
uses the value of L</slug>, but that is not guaranteed to be unchanging.
Ideally it is something more stable.

=item subtitle

The subtitle of the talk.

=item track

Returns a track object of the type as set in
L<SReview::Schedule::Base::Event/track_type> for the track that this
talk is part of.

=item description

A longer description of the talk. Optional.

=item flags

A hash ref of default flags to set on the talk.

=item speakers

Returns an array of L<SReview::Schedule::Base::Speaker> (or subclass)
objects representing the speakers of the talk.

=item filtered

Boolean. If true, the talk will not be added to the schedule. If the
talk is I<already> added to the schedule and it is still in the
C<waiting_for_files> state, it will be moved to the C<ignored> state,
instead.

=item extra_data

Any extra data that should be stored with the talk. Can be used later in credits
slides or other templates, as required.

=back
