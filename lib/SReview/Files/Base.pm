package SReview::Files::Base;

use Moose;

has 'is_collection' => (
	isa => 'Bool',
	is => 'ro',
);

has 'url' => (
	isa => 'Str',
	is => 'ro',
	lazy => 1,
	builder => '_probe_url',
);

has 'download_verbose' => (
        is => 'rw',
        isa => 'Bool',
        default => 0,
);

no Moose;

1;

__END__

=head1 NAME

SReview::Files::Base - Base class for all SReview::Files classes

=head1 DESCRIPTION

The L<SReview::Files::Base> class is the base class for all
C<SReview::Files> classes. It should not be used directly, but it contains
contains a few properties that are required for all C<SReview::Files>
classes.

=head1 PROPERTIES

=head2 C<is_collection>

The C<is_collection> property is a boolean indicating whether the
object is a collection or not.

=head2 C<url>

The C<url> property is the URL of the object. It is lazy and will
be computed on demand.

=head2 C<download_verbose>

The C<download_verbose> property is a boolean indicating whether
verbose output should be printed when downloading files. Defaults to
false.

=head1 AUTHOR

Wouter Verhelst <w@uter.be>

=cut
