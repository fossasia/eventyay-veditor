package SReview::Files::Access::Base;

use Moose;
use DateTime;
use Carp;

extends 'SReview::Files::Base';

has '+is_collection' => (
	default => 0,
);

has 'relname' => (
	is => 'rw',
	isa => 'Str',
	required => 1,
);

has 'filename' => (
	isa => 'Str',
	is => 'ro',
	lazy => 1,
	builder => '_get_file',
);

has 'mtime' => (
	isa => 'DateTime',
	is => 'ro',
	lazy => 1,
	builder => '_probe_mtime',
);

has 'baseurl' => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has 'basepath' => (
	isa => 'Str',
	is => 'ro',
	lazy => 1,
	builder => '_probe_basepath',
);

has 'create' => (
	is => 'rw',
	traits => ['Bool'],
	isa => 'Bool',
	default => 0,
	required => 1,
	handles => {
		has_data => 'not',
	},
);

has 'is_stored' => (
	is => 'ro',
	isa => 'Bool',
	traits => ['Bool'],
	default => 0,
	handles => {
		auto_save => 'unset',
		no_auto_save => 'set',
		stored => 'set',
	},
);

sub valid_path_filename {
        ...
}

sub store_file {
        ...
}

sub delete {
        ...
}

sub _probe_url {
	my $self = shift;

	return join('/', $self->baseurl, $self->relname);
}

sub _probe_basepath {
	return shift->baseurl;
}

sub DEMOLISH {
	my $self = shift;
	if($self->create) {
		if(!$self->is_stored) {
			carp "object destructor for '" . $self->url . "' entered without an explicit store, storing now...";
			$self->store_file;
		}
	}
}

no Moose;

1;

__END__

=head1 NAME

SReview::Files::Access::Base - Base class for file access methods

=head1 DESCRIPTION

This class is used as a base class for all C<SReview::Files> classes
that provide access to files (as opposed to directories). It should not
be used directly, but it defines the API to access files using the
C<SReview::Files> API.

=head1 PROPERTIES

=head2 relname

The relative name of the file, inside the collection. Required at object
creation time. Should contain the full path from the root of the
collection.

=head2 filename

An absolute pathname that points to a readable version of the data file,
I<on the local filesystem>. Its builder, C<_get_file>, I<must> be
implemented by subclasses.

If the file is not currently available on the local filesystem, the
C<_get_file> method should do whatever is required to ensure that it
somehow is (e.g., download the file to a temporary directory), and then
return the filename to the file that it now made available. The created
file I<must> have the same extension so that other parts of SReview can
correctly recognize the file type, but is not otherwise required to have
any part of L</relname> in the name.

If the L</create> property is true, the caller wants to create or
overwrite the contents of the file. In this case, the C<_get_file>
method should not download a file, but should still return a filename
with the correct extension.

=head2 mtime

The modification time of the file. Used by L<sreview-detect> to determine
if a file has changed since it was last seen.

=head2 baseurl

A copy of the containing collection's
L<baseurl|SReview::Files::Collection::Base/baseurl> property. Done as an
optimization, so that an implementation doesn't have to look up the
collection in use in order to build the full URL when needed.

=head2 basepath

The base path of the filename; the part that comes before the
L</valid_path_filename>. For the L<SReview::Files::Access::direct>
implementation, this is the same as L</baseurl>. For other
implementations, this could be the name of a temporary directory or
something along those lines.

=head2 create

Boolean. The caller should set this property to true if it wants to
write to the file, and to false if it wants to read from the file.

Creating an object that can be used both for reading and writing at the
same time is not supported.

=head2 is_stored

Boolean. Indicates that the file has been uploaded to the server, if
required. Used by the destructor to detect forgotten L</store_file>
calls, and make them implicit.

=head1 METHODS

=head2 valid_path_filename

The C<valid_path_filename> method should be implemented by subclasses
to return the path to the file on the local filesystem. It differs from
the L</filename> property in that the returned filename I<must> end with
the value of the L</relname> property. However, it I<may> do this by way
of a symlink to the file pointed to by the L</filename> property.

Future versions of this API may implement this as a lazy property rather
than a subroutine.

=head2 store_file

This method should be implemented by subclasses to write
the contents of the file to the correct location on the server. After
successfully uploading the file, the L</is_stored> property should be
set to true.

Read-only implementations of the C<SReview::Files> API (e.g.,
L<SReview::Files::Access::HTTP>) do not need to provide this method.

If no upload is required, the method should still set the L</is_stored>
property to true.

=head2 delete

This method should be implemented by subclasses to delete the file from
the collection.

Read-only implementations of the C<SReview::Files> API (e.g.,
L<SReview::Files::Access::HTTP>) do not need to provide this method.

=head1 AUTHOR

Wouter Verhelst <w@uter.be>

=cut
