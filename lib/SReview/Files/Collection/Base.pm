package SReview::Files::Collection::Base;

use Moose;
use Carp;

extends 'SReview::Files::Base';

has '+is_collection' => (
	default => 1,
);

has 'children' => (
	isa => 'ArrayRef[SReview::Files::Base]',
	traits => ['Array'],
	is => "ro",
	lazy => 1,
	handles => {
		sorted_files => 'sort',
	},
	builder => '_probe_children',
);

has 'baseurl' => (
	isa => 'Str',
	is => 'ro',
	predicate => 'has_baseurl',
	writer => '_set_baseurl',
	lazy => 1,
	builder => '_probe_baseurl',
);

has 'globpattern' => (
	isa => 'Str',
	is => 'ro',
	predicate => 'has_globpattern',
	lazy => 1,
	builder => '_probe_globpattern',
);

has 'fileclass' => (
	isa => 'Str',
	is => 'ro',
	required => 1,
);

has 'collection_name' => (
        isa => 'Str',
        is => 'ro',
        default => '(unknown)',
        lazy => 1,
);

sub _probe_baseurl {
	my $self = shift;
	
	if(!$self->has_globpattern) {
		croak("either a globpattern or a baseurl are required!\n");
	}
	@_ = split(/\*/, $self->globpattern);

	my $rv = $_[0];
	while(substr($rv, -1) eq '/') {
		substr($rv, -1) = '';
	}

	return $rv;
}

sub _probe_url {
	return shift->baseurl;
}

sub _probe_globpattern {
	my $self = shift;

	if(!$self->has_baseurl) {
		croak("either a globpattern or a baseurl are required!\n");
	}
	return join('/', $self->baseurl, '*');
}

sub _create {
	my $self = shift;
	my %options = @_;

	if(exists($options{fullname})) {
		if(substr($options{fullname}, 0, length($self->baseurl)) ne $self->baseurl) {
			croak($options{fullname} . " is not accessible through this collection");
		}
		$options{relname} = substr($options{fullname}, length($self->baseurl));
		while(substr($options{relname}, 0, 1) eq '/') {
			$options{relname} = substr($options{relname}, 1);
		}
		delete $options{fullname};
	}

	$options{baseurl} = $self->baseurl;

	my $fileclass = $self->fileclass;

	return "$fileclass"->new(%options);
}

sub get_file {
	my $self = shift;
	my %options = @_;

	$options{create} = 0;

	return $self->_create(%options);
}

sub add_file {
	my $self = shift;
	my %options = @_;

	$options{create} = 1;

	return $self->_create(%options);
}

sub has_file {
	my $self = shift;
	my $target = shift;

	return scalar(grep({(!$_->is_collection) && ($_->relname eq $target)} @{$self->children}));
}

sub delete_files {
	my $self = shift;
	my %options = @_;

	my @names;
	if(exists($options{files})) {
		@names = sort(@{$options{files}});
	} elsif(exists($options{relnames})) {
		@names = map({join('/', $self->baseurl, $_)} sort(@{$options{relnames}}));
	} else {
		croak("need list of files, or list of relative names");
	}
	my @ownfiles = sort({$a->url cmp $b->url} @{$self->children});
	my @to_delete = ();

	while(scalar(@names) && scalar(@ownfiles)) {
		if($ownfiles[0]->is_collection) {
			if($names[0] eq $ownfiles[0]->baseurl) {
				push @to_delete, shift @ownfiles;
				shift @names;
			} elsif(substr($names[0], 0, length($ownfiles[0]->baseurl)) eq $ownfiles[0]->baseurl) {
				$ownfiles[0]->delete_files(files => [$names[0]]);
				shift @names;
			}
			shift @ownfiles;
		} elsif($names[0] eq $ownfiles[0]->url) {
			shift @names;
			push @to_delete, shift @ownfiles;
		} elsif($names[0] eq substr($ownfiles[0]->url, 0, length($names[0]))) {
			push @to_delete, shift @ownfiles;
			if((!scalar(@ownfiles)) || $names[0] ne substr($ownfiles[0]->url, 0, length($names[0]))) {
				shift @names;
			}
		} elsif ($names[0] gt $ownfiles[0]->url) {
			shift @ownfiles;
		} else {
			carp "ignoring request to delete file or directory ${names[0]} from collection " . $self->collection_name . ", as it does not exist";
			shift @names;
		}
	};
	if(scalar(@names)) {
                carp "ignoring request to delete file or directory ${names[0]} from collection " . $self->collection_name . ", as it does not exist";
	}
	foreach my $file(@to_delete) {
		$file->delete;
	}
}

sub delete {
	my $self = shift;

	foreach my $child(@{$self->children}) {
		$child->delete;
	}
}

no Moose;

1;

__END__

=head1 NAME

SReview::Files::Collection::Base - Base class for file collections

=head1 DESCRIPTION

This class is used as a base class for all C<SReview::Files::Collection>
classes.

For SReview, a collection is a "container" of files, like a directory.
The implementation requires that each file object in the collection has
a URL created by the collection's L</baseurl> property, followed by a
slash, and the relative name of the file.

=head1 PROPERTIES

=head2 children

An array of L<SReview::Files::Base> objects, one for each file in the
collection.

This is a lazy property, and will be computed on demand based on the
files that are, at that point in time, actually available in the
collection, through its builder, C<_probe_children>, which needs to be
implemented by the implementing class if indexing of files is supported.

Some implementations do not support this. These implementations (e.g.,
L<SReview::Files::Collection::HTTP>) do not need to implement the
C<_probe_children> method.

Note: the definition allows for collections to contain more collections.
However, this turned out to be problematic, and so the current
implementation expects that the L</children> property of collections
created by L<SReview::Files::Factory/create> only returns
L<SReview::Files::Access> objects. However, as some implementations
might want to internally use a collection that I<does> use a collection
of collections, this is not enforced at the API level.

=head2 baseurl

The base URL of the collection. Either this property or the
L</globpattern> one is required.

Defaults to the leading part of the L</globpattern> up to the last
character before the first C<*> character, with trailing slashes, if
any, removed.

Need not be a valid absolute URL; e.g., the
L<SReview::Files::Collection::direct> implementation uses an absolute
path that contains the collection.

=head2 globpattern

The globpattern is used by some implementations' L</children> property
to find the files in the collection.

Either this property or the L</baseurl> one is required.

=head2 fileclass

The name of the L<SReview::Files::Access::Base> subclass used for files
found in the collection.

Required.

=head2 collection_name

The name of the collection. Used in some debugging methods.

=head1 METHODS

=head2 get_file

Helper method to create an object of the L</fileclass> class for files
that already exist in the collection.

Any valid properties for the L</fileclass> class can be specified as
arguments. It explicitly sets the L</create> property to false.

=head2 add_file

Helper method to create an object of the L</fileclass> class for files
that do not yet exist in the collection.

Any valid properties for the L</fileclass> class can be specified as
arguments. It explicitly sets the L</create> property to true.

=head2 has_file

Helper method to determine if the file with the given L</relname>
property exists in the collection.

The default implementation is an inefficient search over the list of
files returned by the L</children> property. Where possible, subclasses
should implement a more efficient method of testing the file's
existence.

=head2 delete_files

Helper method to delete multiple files in the collection.

Can be called in one of two ways. 

=over

=item *

Use the C<files> argument to pass an arrayref of absolute filenames:

  $coll->delete_files(files => ["/foo/bar", "/foo/baz"]);

=item *

Use the C<relnames> argument to pass an arrayref of relative filenames:

  $coll->delete_files(relnames => ["bar", "baz"]);

=back

Either way, the list of files to delete I<must> be within the
collection; any files that are not a part of the collection will not be
deleted.

A file is deleted if it shares a prefix with one of the items in the
list; e.g., if the absolute path of the collection is C</foo>, and the
collection contained files "bar/test123", "baz", and "bazy", then in the
above two examples all those files would be removed.

If a prefix passed does not exist within the collection, a
L<warning|Carp::carp> is printed but this will not be considered an
error.

=head2 delete

Helper method to delete the collection.

The default implementation only deletes all the files in the collection.
Subclasses should implement deleting the collection itself (e.g., by
deleting an S3 bucket, or deleting the directory in which the files of
the collection are found).
