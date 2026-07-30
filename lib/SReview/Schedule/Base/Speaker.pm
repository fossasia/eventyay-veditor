package SReview::Schedule::Base::Speaker;

use Moose;

has 'talk_object' => (
	is => 'ro',
	isa => 'SReview::Schedule::Base::Talk',
	weak_ref => 1,
	required => 1,
);

has 'name' => (
	is => 'ro',
	isa => 'Str',
	lazy => 1,
	builder => '_load_name',
);

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
	return undef;
}

no Moose;

1;

__END__

=head1 NAME

SReview::Schedule::Base::Speaker

=head1 DESCRIPTION

A class to hold a speaker.

=head1 ATTRIBUTES

=over

=item talk_object

The C<SReview::Schedule::Base::Talk> object that this speaker is
associated with. This is a weak reference. Required at construction
time.

=item name

The name of the speaker, as it appears on the schedule. No C<load>
method is implemented here, that must be done by the subclass.

=item email

The email address of the speaker. If set, L<sreview-notify> can send
emails to the speaker.

=item upstreamid

The unique, unchanging ID of the speaker in the schedule. If not set,
C<sreview-import> cannot be idempotent and every time the schedule
parser is run, more speakers are added to the database.

=back
