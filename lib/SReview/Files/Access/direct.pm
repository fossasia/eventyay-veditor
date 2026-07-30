package SReview::Files::Access::direct;

use Moose;
use DateTime;
use File::Path qw/make_path/;
use File::Basename qw/dirname/;

extends 'SReview::Files::Access::Base';

sub _get_file {
	my $self = shift;

	if($self->create) {
		make_path(dirname($self->url));
		unlink($self->url);
	}
	return $self->url;
}

sub store_file {
	my $self = shift;
	$self->stored;
	return 1;
}

sub _probe_mtime {
	my $self = shift;
	my @stat = stat($self->filename);

	return DateTime->from_epoch(epoch => $stat[9]);
}

sub delete {
	my $self = shift;

	unlink($self->url);
}

sub valid_path_filename {
	my $self = shift;

	return $self->url;
}

no Moose;

1;

__END__

=head1 NAME

SReview::Files::Access::direct - Direct file access

=head1 DESCRIPTION

The L<SReview::Files::Access::direct> class implements access to files
in collections that are stored directly on the filesystem, either on
local partitions or mounted over a network filesystem such as NFS or
sshfs. It is the default implementation of the L<SReview::Files::Access>
API.

It provides an implementation of the
L<SReview::Files::Access::Base/store_file> method that does not upload
anything (as files are directly accessible), of the 
L<SReview::Files::Access::Base/delete> method that calls L<unlink>, and
of the L<SReview::Files::Access::Base/valid_path_filename> method that
returns the value of the L<SReview::Files::Base/url> property.

=head1 SEE ALSO

L<SReview::Files::Base>, L<SReview::Files::Access::Base>
