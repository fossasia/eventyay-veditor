package SReview::Schedule::Base::Event;

use Moose;
use Moose::Util::TypeConstraints;
use DateTime::TimeZone;

has 'root_object' => (
	isa => 'SReview::Schedule::Base',
	is => 'ro',
	weak_ref => 1,
	required => 1,
);

has 'talks' => (
	is => 'ro',
	lazy => 1,
	isa => 'ArrayRef[SReview::Schedule::Base::Talk]',
	builder => '_load_talks',
);

sub _load_talks {
	return [];
}

has 'name' => (
	is => 'ro',
	lazy => 1,
	isa => 'Str',
	builder => '_load_name',
);

sub _load_name {
	return "";
}

class_type "DateTime::TimeZone";
coerce "DateTime::TimeZone",
        from "Str",
        via  { DateTime::TimeZone->new(name => $_) };

has 'timezone' => (
	is => 'ro',
	isa => 'DateTime::TimeZone',
	lazy => 1,
        coerce => 1,
	builder => '_load_timezone',
);

sub _load_timezone {
	return DateTime::TimeZone->new(name => 'local');
}

1;

__END__

=head1 NAME

SReview::Schedule::Base::Event

=head1 DESCRIPTION

A class to hold an event

=head1 ATTRIBUTES

=over

=item root_object

The L<SReview::Schedule::Base> (or subclass) object that this event is from.

=item talks

An array of L<SReview::Schedule::Base::Talk> (or subclass) object(s) that are
found in this event.

=item timezone

The timezone in which this event takes place, as a
L<DateTime::TimeZone>. Note that a coercion is in place to convert it
from a string representation.
