package SReview::Schedule::Multi::ShadowTalk;

use Moose;
use SReview::Schedule::WithShadow;

extends 'SReview::Schedule::WithShadow::ShadowedTalk';

has 'prefix' => (
	is => 'ro',
	isa => 'Str',
	default => '',
);

has 'suffix' => (
	is => 'ro',
	isa => 'Str',
	default => '',
);

sub _load_title {
	my $self = shift;
	return $self->prefix . $self->shadow->title . $self->suffix;
}

no Moose;

package SReview::Schedule::Multi::ShadowEvent;

use Moose;
use SReview::Schedule::WithShadow;

extends 'SReview::Schedule::WithShadow::ShadowedEvent';

has 'talk_prefix' => (
	is => 'ro',
	isa => 'Str',
);

has 'talk_suffix' => (
	is => 'ro',
	isa => 'Str',
);

has 'event_prefix' => (
	is => 'ro',
	isa => 'Str',
	default => '',
);

has 'event_suffix' => (
	is => 'ro',
	isa => 'Str',
	default => '',
);

has 'talk_opts' => (
	is => 'ro',
	isa => 'HashRef',
	default => sub { {} },
);

sub _load_talks {
	my $self = shift;
	my $rv = [];
	my $opts = $self->talk_opts;
	my $talk_type = $self->root_object->talk_type;
	foreach my $talk(@{$self->shadow->talks}) {
		push @$rv, $talk_type->new(shadow => $talk,
					   prefix => $self->talk_prefix,
					   suffix => $self->talk_suffix, 
					   event_object => $self,
					   %$opts);
	}
	return $rv;
}

sub _load_name {
	my $self = shift;
	return $self->event_prefix . $self->shadow->name . $self->event_suffix;
}

package SReview::Schedule::Multi;

=head1 NAME

SReview::Schedule::Multi - system to duplicate event parsing into a main and a shadow one.

=head1 SYNOPSIS

  $schedule_format = "multi";
  $schedule_options = { url => "http://...", base_type => "penta", base_options => {},
      shadows => [{ talk_prefix => "Video for talk '", talk_suffix => "'",
                    event_prefix => "Videos for event '", event_suffix => "'", talk_opts => {} }]};

=head1 DESCRIPTION

SReview::Schedule::Multi is a schedule parser for L<sreview-import> that
creates "shadow" events based on a base event. This can be used when
multiple events are required in SReview for an upstream event (e.g., one
for preprocessing, and one for postprocessing).

=head1 OPTIONS

SReview::Schedule::Multi takes the following options:

=head2 base_type

The type of the parser of the base event. Must be another
C<SReview::Schedule::> parser. Required.

=head2 base_options

Any options, other than the C<url> option, to be passed to the base
parser to configure it. Optional.

=head2 url

The URL of the schedule. Passed on, unmodified, to the base parser.

=head2 shadows

An array of hashes, one for each shadow event that is to be created.

Each hash can have the following options:

=head3 event_prefix

A string that will be prepended to the event's name.

=head3 event_suffix

A string that will be appended to the event's name.

=head3 talk_prefix

A string that will be prepended to each and every talk's title.

=head3 talk_suffix

A string that will be appended to each and every talk's title.

=head3 talk_opts

Extra properties to be sent to the SReview::Schedule::<base_type>::Talk
object at creation time. This can be used to override certain properties
of the talk, e.g., the flags.

=head1 SEE ALSO

L<SReview::Schedule::Penta>, L<SReview::Schedule::Wafer>

=cut

use Moose;
use SReview::Schedule::WithShadow;

extends 'SReview::Schedule::WithShadow';

has 'shadows' => (
	is => 'ro',
	isa => 'ArrayRef[HashRef[Any]]',
	required => 1,
);

sub _load_events {
	my $self = shift;
	my $rv_type = "SReview::Schedule::" . ucfirst($self->base_type);
	eval "require $rv_type;" or die $!;
	my $opts = $self->base_options;
	$opts = {} unless defined($opts);
	$opts->{url} = $self->url;
	my $base_parser = "$rv_type"->new(%$opts);
	my $rv = [];
	my $event_type = $self->event_type;
	foreach my $event(@{$base_parser->events}) {
		push @$rv, $event;
		foreach my $shadow(@{$self->shadows}) {
			push @$rv, $event_type->new(shadow => $event, %$shadow, root_object => $self);
		}
	}
	return $rv;
}

sub _load_talk_type {
	return "SReview::Schedule::Multi::ShadowTalk";
}

sub _load_event_type {
	return "SReview::Schedule::Multi::ShadowEvent";
}

1;
