package SReview::Schedule::Base::Track;

use Moose;
use Mojo::Util 'slugify';

has 'talk_object' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Talk',
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

has 'email' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_email',
);

sub _load_email {
	return undef;
}

has 'upstreamid' => (
	is => 'ro',
	isa => 'Maybe[Str]',
	lazy => 1,
	builder => '_load_upstreamid',
);

sub _load_upstreamid {
	return slugify(shift->name);
}

1;

__END__

=head1 NAME

SReview::Schedule::Base::Track

=head1 DESCRIPTION

A class to hold a track.

=head1 ATTRIBUTES

=over

=item talk_object

The talk object associated with this track. This is a weak reference to
a C<SReview::Schedule::Base::Talk> object (or subclass). Must be
specified at construction time.

=item name

The name of the track.

=item email

An email address associated with the track. If set, then
C<sreview-notify> will Cc this email address when sending out emails.

=item upstreamid

A unique, unchanging ID used by the schedule. If not set, it uses a slug
version of the L</name> attribute, which is not unchanging and therefore
not idempotent. If set, L<sreview-import> will use this to recognize
existing tracks and update them rather than creating new ones.

=back
