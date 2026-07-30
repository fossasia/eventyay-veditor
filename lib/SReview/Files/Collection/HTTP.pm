package SReview::Files::Collection::HTTP;

use Moose;
use Carp;
use SReview::Files::Access::HTTP;

extends 'SReview::Files::Collection::Base';

has '+fileclass' => (
	default => 'SReview::Files::Access::HTTP',
);

sub add_file {
	croak "Creating files is not supported on an HTTP collection";
}

sub _probe_children {
	croak "Discovering children is not supported on an HTTP collection";
}

1;
