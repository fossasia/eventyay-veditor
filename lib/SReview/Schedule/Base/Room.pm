package SReview::Schedule::Base::Room;

use Moose;

has 'event_object' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Event',
	weak_ref => 1,
	required => 1,
);

has 'name' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_name',
);

sub _load_name {
	return undef;
}

has 'altname' => (
	is => 'rw',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_altname',
);

sub _load_altname {
	return undef;
}

has 'outputname' => (
	is => 'rw',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_outputname',
);

sub _load_outputname {
	return undef;
}

1;

__END__

=head1 NAME

SReview::Schedule::Base::Room

=head1 DESCRIPTION

A class to hold a room.

=head1 ATTRIBUTES

=over

=item event_object

The C<SReview::Schedule::Base::Event> (or subclass) object that this
room is part of. Required at construction time; this is a weak
reference.

=item name

The name of the room.

=item altname

An alternative name for the room. This is the name of the room by which
L<sreview-detect> will assign video files to rooms.

=item outputname

The output name for the room. This is the name of the room as used by
L<sreview-transcode> and L<sreview-upload>, i.e., the directory in which
files are stored in the output system.

=back
