package SReview::Schedule::Ics::Speaker;

use Moose;
use Mojo::Util 'slugify';

extends 'SReview::Schedule::Base::Speaker';

sub _load_upstreamid {
	return slugify(shift->name);
}

package SReview::Schedule::Ics::Track;

use Moose;
use Mojo::Util 'slugify';

extends 'SReview::Schedule::Base::Track';

sub _load_upstreamid {
	return slugify(shift->name);
}

package SReview::Schedule::Ics::Talk;

use Moose;

extends 'SReview::Schedule::Base::Talk';

has 'room_name' => (
	is => 'ro',
	isa => 'Str',
	default => 'main',
);

sub _load_room {
	my $self = shift;
	return $self->event_object->root_object->room_type->new(name => $self->room_name, event_object => $self->event_object);
}

has 'track_name' => (
	is => 'ro',
	isa => 'Str',
	default => 'main',
);

sub _load_track {
	my $self = shift;
	return $self->event_object->root_object->track_type->new(name => $self->track_name, talk_object => $self);
}

has 'speaker_name' => (
	is => 'ro',
	isa => 'Str',
	predicate => 'have_speaker_name',
);

sub _load_speakers {
	my $self = shift;
	if($self->have_speaker_name) {
		return [$self->event_object->root_object->speaker_type->new(name => $self->speaker_name, talk_object => $self)];
	}
	return undef;
}

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

sub _load_starttime {
	return shift->schedref->{DTSTART};
}

sub _load_endtime {
	return shift->schedref->{DTEND};
}

sub _load_filtered {
	return 0;
}

sub _load_title {
	return shift->schedref->{SUMMARY};
}

package SReview::Schedule::Ics::Event;

use Moose;

extends 'SReview::Schedule::Base::Event';

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

has "talk_opts" => (
	is => "ro",
	isa => "HashRef",
);

has 'summary_regex' => (
	is => 'ro',
	isa => 'Str',
	predicate => 'have_regex',
);

sub _load_talks {
	my $self = shift;
	my $rv = [];
	my $talk_opts = $self->talk_opts;
	foreach my $year(values %{$self->schedref->{events}}) {
		foreach my $month(values %$year) {
			foreach my $day(values %$month) {
				foreach my $talk(values %$day) {
					my $talk_obj = $self->root_object->talk_type->new(schedref => $talk, %$talk_opts, event_object => $self);
					if($self->have_regex) {
						my $summary = $talk->{SUMMARY};
						next unless $summary =~ $self->summary_regex;
						foreach my $field(keys %+) {
							$talk_obj->meta->find_attribute_by_name($field)->set_value($talk_obj, $+{$field});
						}
					}
					push @$rv, $talk_obj;
				}
			}
		}
	}
	return $rv;
}

package SReview::Schedule::Ics;

=head1 NAME

SReview::Schedule::Ics - sreview-import schedule parser for schedules in ICS format

=head1 SYNOPSIS

  $schedule_format = "ics";
  $schedule_options = { url => "https://...", event_opts => { name => 'My conference', talk_opts => { track_name => "My track", room_name => "My room"} } };

=cut

use Moose;
use iCal::Parser;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base';

has "event_opts" => (
	is => 'ro',
	isa => 'HashRef[Any]',
	default => sub { {} },
);

sub _load_talk_type {
	return "SReview::Schedule::Ics::Talk";
}

sub _load_speaker_type {
	return "SReview::Schedule::Ics::Speaker";
}

sub _load_track_type {
	return "SReview::Schedule::Ics::Track";
}

sub _load_event_type {
	return "SReview::Schedule::Ics::Event";
}

sub _load_events {
	my $self = shift;
	my $ics = iCal::Parser->new;
	$ics->parse_strings($self->_get_raw);
	my $event_opts = $self->event_opts;
	return [$self->event_type->new(schedref => $ics->calendar, %$event_opts, root_object => $self)];
}

1;
