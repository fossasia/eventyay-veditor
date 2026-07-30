package SReview::Schedule::WithShadow::ShadowedSpeaker;

use Moose;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base::Speaker';

has 'shadow' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Speaker',
	required => 1,
);

sub _load_name {
	return shift->shadow->name;
}

sub _load_email {
	return shift->shadow->email;
}

sub _load_upstreamid {
	return shift->shadow->upstreamid;
}

no Moose;

package SReview::Schedule::WithShadow::ShadowedRoom;

use Moose;

extends 'SReview::Schedule::Base::Room';

has 'shadow' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Room',
	required => 1,
);

sub _load_name {
	return shift->shadow->name;
}

sub _load_altname {
	return shift->shadow->altname;
}

sub _load_outputname {
	return shift->shadow->outputname;
}

no Moose;

package SReview::Schedule::WithShadow::ShadowedTrack;

use Moose;

extends 'SReview::Schedule::Base::Track';

has 'shadow' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Track',
	required => 1,
);

sub _load_name {
	return shift->shadow->name;
}

sub _load_email {
	return shift->shadow->email;
}

sub _load_upstreamid {
	return shift->shadow->upstreamid;
}

no Moose;

package SReview::Schedule::WithShadow::ShadowedTalk;

use Moose;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base::Talk';

has 'shadow' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Talk',
	required => 1,
);

sub _load_speaker_type {
	return 'SReview::Schedule::WithShadow::ShadowedSpeaker';
}

has 'speaker_opts' => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

sub _load_track_type {
	return 'SReview::Schedule::WithShadow::ShadowedTrack';
}

has 'track_opts' => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

sub _load_room_type {
	return 'SReview::Schedule::WithShadow::ShadowedRoom';
}

has 'room_opts' => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

sub _load_room {
	my $self = shift;
	my $type = $self->event_object->root_object->room_type;
	return $type->new(shadow => $self->shadow->room, %{$self->room_opts}, event_object => $self->event_object);
}

sub _load_slug {
	return shift->shadow->slug;
}

sub _load_starttime {
	return shift->shadow->starttime;
}

sub _load_endtime {
	return shift->shadow->endtime;
}

sub _load_length {
	return shift->shadow->length;
}

sub _load_title {
	return shift->shadow->title;
}

sub _load_upstreamid {
	return shift->shadow->upstreamid;
}

sub _load_subtitle {
	return shift->shadow->subtitle;
}

sub _load_track {
	my $self = shift;
	my $type = $self->event_object->root_object->track_type;
	return $type->new(shadow => $self->shadow->track, %{$self->track_opts}, talk_object => $self);
}

sub _load_description {
	return shift->shadow->description
}

sub _load_flags {
	return shift->shadow->flags;
}

sub _load_speakers {
	my $self = shift;
	my $rv = [];
	my $type = $self->event_object->root_object->speaker_type;
	foreach my $speaker(@{$self->shadow->speakers}) {
		push @$rv, "$type"->new(shadow => $speaker, %{$self->speaker_opts}, speaker_object => $self);
	}
	return $rv;
}

sub _load_filtered {
	return shift->shadow->filtered;
}

no Moose;

package SReview::Schedule::WithShadow::ShadowedEvent;

use Moose;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base::Event';

has 'shadow' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Event',
	required => 1,
);

has 'talk_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_talk_type',
);

has 'talk_opts' => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

sub _load_talk_type {
	return "SReview::Schedule::WithShadow::ShadowedTalk";
}

sub _load_talks {
	my $self = shift;
	my $rv = [];
	my $type = $self->root_object->talk_type;
	my $opts = $self->talk_opts;
	foreach my $talk(@{$self->shadow->talks}) {
		push @$rv, $type->new(shadow => $talk, %$opts, event_object => $self);
	}
	return $rv;
}

sub _load_name {
	return shift->shadow->name;
}

no Moose;

package SReview::Schedule::WithShadow;

use Moose;

extends 'SReview::Schedule::Base';

has 'event_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_event_type',
);

#with "MooseX::Deprecated" => {
#       attributes => ["event_type"],
#};

sub _load_eventtype {
        my $self = shift;
	if (my $typefactory = $self->can("_load_event_type")) {
		return $self->$typefactory;
	}
	return $self->SUPER::_load_eventtype;
}

has 'event_opts' => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

has 'base_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_base_type',
);

has 'base_options' => (
	is => 'ro',
	isa => 'HashRef[Any]',
);

sub _load_events {
	my $self = shift;
	my $event_type = $self->eventtype;
	my $base_type = "SReview::Schedule::" . ucfirst($self->base_type);
	eval "require $base_type" or die $!;
	my $event_opts = $self->event_opts;
	my $rv = [];
	foreach my $event(@{$base_type->new(url => $self->url)->events}) {
		push @$rv, $event_type->new(shadow => $event, %$event_opts);
	}
	return $rv;
}

no Moose;

1;
