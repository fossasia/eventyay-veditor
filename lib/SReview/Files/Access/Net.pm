package SReview::Files::Access::Net;

use Moose;
use File::Temp qw/tempfile tempdir mktemp/;
use File::Path qw/make_path/;
use File::Basename;
use Carp;

use SReview::Config::Common;

extends 'SReview::Files::Access::Base';

has '+filename' => (
        predicate => 'has_download',
);

has 'workdir' => (
        is => 'ro',
        lazy => 1,
        builder => '_get_workdir',
);

sub _get_workdir {
        return tempdir(DIR => SReview::Config::Common::setup()->get("workdir"), CLEANUP => 1);
}

sub _get_file {
        ...
}

sub _probe_mtime {
        ...
}

sub _probe_basepath {
        return shift->workdir;
}

sub store_file {
        my $self = shift;
        $self->stored;
        return 1;
}

sub delete {
        ...
}

sub valid_path_filename {
        my $self = shift;

        my $path = join('/', $self->workdir, $self->relname);
        make_path(dirname($path));
        symlink($self->filename, $path);
        return $path;
}

sub DEMOLISH {
        my $self = shift;
        if($self->has_download) {
                if($self->download_verbose) {
                        print "removing " . $self->filename . "\n";
                }
                unlink($self->filename);
        }
}

no Moose;

1;
