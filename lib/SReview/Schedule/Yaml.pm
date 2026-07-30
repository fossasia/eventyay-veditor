package SReview::Schedule::Yaml::Room;

use Moose;

extends "SReview::Schedule::Base::Room";

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

sub _load_name {
	my $self = shift;
	return $self->schedref->{name} if(exists $self->schedref->{name});
	return $self->SUPER::_load_name;
}

sub _load_altname {
	my $self = shift;
	return $self->schedref->{altname} if(exists $self->schedref->{altname});
	return $self->SUPER::_load_altname;
}

sub _load_outputname {
	my $self = shift;
	return $self->schedref->{outputname} if(exists $self->schedref->{outputname});
	return $self->SUPER::_load_outputname;
}

no Moose;
package SReview::Schedule::Yaml::Track;

use Moose;

extends 'SReview::Schedule::Base::Track';

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

sub _load_name {
	my $self = shift;
	return $self->schedref->{name} if (exists($self->schedref->{name}));
	return $self->SUPER::_load_name;
}

sub _load_email {
	my $self = shift;
	return $self->schedref->{email} if (exists($self->schedref->{email}));
	return $self->SUPER::_load_email;
}

sub _load_upstreamid {
	my $self = shift;
	return $self->schedref->{id} if (exists($self->schedref->{id}));
	return $self->SUPER::_load_upstreamid;
}

no Moose;
package SReview::Schedule::Yaml::Talk;

use Moose;
use DateTime::Format::Strptime;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base::Talk';

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

has 'time_format' => (
	isa => 'Str',
	is => 'ro',
	lazy => 1,
	default => '%F %R',
);

has 'timezone' => (
	isa => 'DateTime::TimeZone',
	is => 'ro',
	default => sub { DateTime::TimeZone->new(name =>'UTC') },
);

has 'date_parser' => (
	is => 'ro',
	isa => 'DateTime::Format::Strptime',
	lazy => 1,
	builder => '_build_datetime',
);

sub _build_datetime {
	my $self = shift;
	return DateTime::Format::Strptime->new(pattern => $self->time_format, time_zone => $self->timezone);
}

sub _load_room {
	my $self = shift;
	return $self->SUPER::_load_room unless exists($self->schedref->{room});
	return $self->event_object->root_object->room_type->new(schedref => $self->schedref->{room}, event_object => $self->event_object) if (ref $self->schedref->{room} eq "HASH");
	# Not $self->room_type here, because we're falling back on the Base type
	return SReview::Schedule::Base::Room->new(name => $self->schedref->{room}, event_object => $self->event__object);
}

sub _load_slug {
	my $self = shift;
	if(exists($self->schedref->{slug})) {
		return $self->schedref->{slug};
	} else {
		return $self->SUPER::_load_slug;
	}
}

sub _load_starttime {
	my $self = shift;
	return $self->date_parser->parse_datetime($self->schedref->{starttime})
}

sub _load_endtime {
	my $self = shift;
	if(exists $self->schedref->{endtime}) {
		return $self->date_parser->parse_datetime($self->schedref->{endtime});
	} else {
		return $self->SUPER::_load_endtime;
	}
}

sub _load_length {
	my $self = shift;
	if(exists $self->schedref->{length_minutes}) {
		return DateTime::Duration->new(minutes => $self->schedref->{length_minutes});
	} else {
		return $self->SUPER::_load_length;
	}
}

sub _load_title {
	return shift->schedref->{title};
}

sub _load_subtitle {
	my $self = shift;
	if(exists $self->schedref->{subtitle}) {
		return $self->schedref->{subtitle};
	} else {
		return $self->SUPER::_load_subtitle;
	}
}

sub _load_upstreamid {
	my $self = shift;
	if(exists $self->schedref->{id}) {
		return $self->schedref->{id};
	} else {
		return $self->SUPER::_load_upstreamid;
	}
}

sub _load_track {
	my $self = shift;
	if(exists $self->schedref->{track}) {
		return $self->event_object->root_object->track_type->new(schedref => $self->schedref->{track}, talk_object => $self);
	} else {
		return $self->SUPER::_load_track;
	}
}

sub _load_description {
	my $self = shift;
	if(exists $self->schedref->{description}) {
		return $self->schedref->{description};
	} else {
		return $self->SUPER::_load_description;
	}
}

sub _load_flags {
	my $self = shift;
	if(exists $self->schedref->{flags}) {
		return $self->schedref->{flags};
	} else {
		return $self->SUPER::_load_flags;
	}
}

sub _load_speakers {
	my $self = shift;
	return $self->SUPER::_load_speakers unless exists $self->schedref->{speakers};
	my $rv = [];
	foreach my $speaker(@{$self->schedref->{speakers}}) {
		if(ref $speaker eq 'HASH') {
			push @$rv, $self->event_object->root_object->speaker_type->new(%$speaker, talk_object => $self);
		} else {
			# Fall back on base implementation
			push @$rv, SReview::Schedule::Base::Speaker->new(name => $speaker, talk_object => $self);
		}
	}
	return $rv;
}

no Moose;
package SReview::Schedule::Yaml::Event;

use Moose;
use SReview::Schedule::Base;

extends 'SReview::Schedule::Base::Event';

has 'schedref' => (
	is => 'ro',
	isa => 'HashRef',
	required => 1,
);

sub _load_name {
	return shift->schedref->{name};
}

sub _load_talks {
	my $rv = [];
	my $self = shift;
	my $tz = $self->schedref->{timezone};
	foreach my $talk(@{$self->schedref->{talks}}) {
		push @$rv, $self->root_object->talk_type->new(schedref => $talk,
						 timezone => $self->timezone,
						 event_object => $self,
					 );
	}
	return $rv;
}

sub _load_timezone {
	my $self = shift;
	if(exists($self->schedref->{timezone})) {
		return DateTime::TimeZone->new(name => $self->schedref->{timezone});
	} else {
		return $self->SUPER::_load_timezone;
	}
}

no Moose;

package SReview::Schedule::Yaml;

use Moose;
use SReview::Schedule::Base;
use YAML::XS;

extends 'SReview::Schedule::Base';

sub _load_events {
	my $self = shift;
	my $yaml = Load($self->_get_raw);
	my %args = (
		schedref => $yaml,
		root_object => $self,
	);
	if($self->has_timezone) {
		$args{timezone} = $self->timezone;
	}
	return [$self->event_type->new(%args)];
}

sub _load_event_type {
	return "SReview::Schedule::Yaml::Event";
}

sub _load_talk_type {
	return "SReview::Schedule::Yaml::Talk";
}

sub _load_room_type {
	return "SReview::Schedule::Yaml::Room";
}

sub _load_track_type {
	return "SReview::Schedule::Yaml::Track";
}

no Moose;

1;
