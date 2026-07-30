package SReview::Files::Collection::direct;

use Moose;
use File::Basename;
use Carp;

extends 'SReview::Files::Collection::Base';

use SReview::Files::Access::direct;

has '+fileclass' => (
	default => 'SReview::Files::Access::direct',
);

sub _probe_children {
	my $self = shift;
	my @return;

	foreach my $file(glob($self->globpattern)) {
		my $child;
		if(-d $file) {
			$child = SReview::Files::Collection::direct->new(baseurl => join("/", $self->baseurl, basename($file)), download_verbose => $self->download_verbose);
		} else {
			my $basename = substr($file, length($self->baseurl));
			while(substr($basename, 0, 1) eq '/') {
				$basename = substr($basename, 1);
			}
			$child = SReview::Files::Access::direct->new(baseurl => $self->baseurl, relname => $basename, download_verbose => $self->download_verbose);
		}
		push @return, $child;
	}

	return \@return;
}

sub has_file {
	my ($self, $target) = @_;

	if(-f join('/', $self->baseurl, $target)) {
		return 1;
	}
	return 0;
}

sub delete {
	my $self = shift;

	$self->SUPER::delete;
	rmdir($self->baseurl);
}

no Moose;

1;

__END__

=head1 NAME

SReview::Files::Collection::direct

=head1 DESCRIPTION

A L<SReview::Files::Collection::Base> subclass that implements direct file
access through the filesystem. Files can be shared across hosts over network
file systems (e.g., NFS or sshfs), or can be local-only.

It provides no extra methods or properties beyond those implemented by
L<SReview::Files::Collection::Base>, but has a more complete implementation of
L<SReview::Files::Collection::Base/delete> and a more efficient one of
L<SReview::Files::Collection::Base/has_file>.

=head1 AUTHOR

Wouter Verhelst <w@uter.be>
