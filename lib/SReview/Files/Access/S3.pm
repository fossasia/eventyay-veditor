package SReview::Files::Access::S3;

use Moose;
use File::Temp qw/tempfile tempdir mktemp/;
use File::Path qw/make_path/;
use File::Basename;
use DateTime::Format::ISO8601;
use Carp;

extends 'SReview::Files::Access::Net';

has 's3object' => (
	is => 'ro',
	required => 1,
	isa => 'Net::Amazon::S3::Bucket',
);

sub _get_file {
	my $self = shift;
	my @parts = split('\.', $self->relname);
	my $ext = pop(@parts);
	my $dir = $self->workdir;

	if($self->has_data) {
                if($self->download_verbose) {
                        print "downloading " . $self->relname . " to " . $self->filename . "\n";
                }
		my ($fh, $file) = tempfile("s3-XXXXXX", dir => $dir, SUFFIX => ".$ext");
		$self->s3object->get_key_filename($self->relname, "GET", $file);
		return $file;
	} else {
		my $file = join("/", $self->workdir, basename($self->relname));
		return $file;
	}
}

sub _probe_mtime {
	my $self = shift;
	my $meta = $self->s3object->head_key($self->relname);

	return DateTime::Format::ISO8601->parse_datetime($meta->{last_modified});
}

sub store_file {
	my $self = shift;
	return if(!$self->has_download);

        if($self->download_verbose) {
                print "uploading " . $self->filename . " to " . $self->onhost_pathname . " via s3\n";
        }

	$self->s3object->add_key_filename($self->relname, $self->filename, {}) or croak($self->s3object->errstr);

	$self->stored;
}

sub delete {
	my $self = shift;
	$self->s3object->delete_key($self->relname)
}

no Moose;

1;
