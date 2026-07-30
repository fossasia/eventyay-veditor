package SReview::Schedule::Base;

use Moose;
use Mojo::UserAgent;
use Mojo::URL;

has 'url' => (
	required => 1,
	is => 'ro',
);

has 'timezone' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	predicate => 'has_timezone',
);

has '_raw' => (
	lazy => 1,
	builder => '_load_raw',
	is => 'bare',
	reader => '_get_raw',
);

sub _load_raw {
	my $self = shift;
	my $ua = Mojo::UserAgent->new;
	$ua->proxy->detect;
	my $url = Mojo::URL->new($self->url);
	if($url->scheme eq "file") {
		local $/ = undef;
		open my $f, "<", $url->host . $url->path;
		my $rv = <$f>;
		close $f;
		return $rv;
	}
	my $res = $ua->get($self->url)->result;
	die "Could not access " . $self->url . ": " . $res->code . " " . $res->message unless $res->is_success;
	return $res->body;
}

has 'speaker_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_speaker_type',
);

sub _load_speaker_type {
	return 'SReview::Schedule::Base::Speaker';
}

has 'room_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_room_type',
);

sub _load_room_type {
	return 'SReview::Schedule::Base::Room';
}

has 'track_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_track_type',
);

sub _load_track_type {
	return 'SReview::Schedule::Base::Track';
}

has 'talk_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_talk_type',
);

sub _load_talk_type {
	return 'SReview::Schedule::Base::Talk';
}

has 'event_type' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_event_type',
);

sub _load_event_type {
	return 'SReview::Schedule::Base::Event';
}

has 'events' => (
	is => 'ro',
	isa => 'ArrayRef[SReview::Schedule::Base::Event]',
	lazy => 1,
	builder => '_load_events',
);

sub _load_events {
	return [];
}

no Moose;
1;

__END__

=head1 NAME

SReview::Schedule::Base

=head1 DESCRIPTION

Base class for all schedule parsers.

The C<SReview::Schedule> API is used by L<sreview-import> in order to parse
schedules. L<sreview-import> will load the desired schedule parsing
class, and ask it for a list of events and talks within those events.

SReview::Schedule is a pull-through API; that is, you get a toplevel
class, which you can ask for a list of events. Each event must be a
subclass of the C<SReview::Schedule::Base::Event>, which can be asked for
a list of talks (as C<SReview::Schedule::Base::Talk> or subclasses of
that). These can then in turn be asked for the room, the speakers, the
start time, etc.

All attributes of a schedule or a talk are implemented as lazy
attributes; that is, they don't have a value until a request is made for
their data. The method that implements fetching the data for a method
should usually be defined the subclass, as a method called
C<_load_>I<attribute>; e.g., to load the C<events> attribute in the
C<SReview::Schedule::Base> class, the C<_load_events> method should be
overridden in the subclass.

Most attributes have a default implementation of the C<_load_*> method
that returns C<undef> or an empty array, so if your schedule format does
not implement fetching the requested data, you can leave out the
relevant C<_load_*> method and everything will work just fine.

=head1 ATTRIBUTES

=over

=item url

I<Required> at class construction time; the only attribute so required.
The URL where the schedule can be found.

=item timezone

Not a lazy attribute by default (can be overridden by a subclass
though). The timezone in which the event takes place. Can optionally be
set at construction time.

=item _raw

Internal attribute. If read, transparently downloads (and caches), then
returns, the raw schedule data from the given L</url>.

=item speaker_type

The class name of the subclass to be used when creating an object to
hold a speaker. Default load implementation returns
C<SReview::Schedule::Base::Speaker>, but can be overridden to anything.

=item room_type

The class name of the subclass to be used when creating an object to
hold a room. Default load implementation returns
C<SReview::Schedule::Base::Room>, but can be overridden to anything.

=item track_type

The class name of the subclass to be used when creating an object to
hold a track. Default load implementation returns
C<SReview::Schedule::Base::Track>, but can be overridden to anything.

=item talk_type

The class name of the subclass to be used when creating an object to
hold a talk. Default load implementation returns
C<SReview::Schedule::Base::Talk>, but can be overridden to anything.

=item event_type

The class name of the subclass to be used when creating an object to
hold an event. Default load implementation returns
C<SReview::Schedule::Base::Event>, but can be overridden to anything.

=item events

Must return the events found in the schedule. For the purpose of
SReview, an "event" is a set of "talks" that should be grouped together.
For instance, "FOSDEM 2025" is an event; the "FOSDEM 2025 opening talk"
is a talk.

Should return an array of C<SReview::Schedule::Base::Event> objects (or
a subclass of them).

=back
