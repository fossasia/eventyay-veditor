package SReview::Files::Access::SFTP;

use Moose;
use Carp;
use Fcntl;
use File::Basename;
use File::Temp qw/tempfile/;

use SReview::Files::Collection::Net;

extends 'SReview::Files::Access::Net';

has 'basepath' => (
        is => 'ro',
        isa => 'Str',
        lazy => 1,
        builder => '_probe_basepath',
);

sub _probe_basepath {
        my $self = shift;

        my $url = Mojo::URL->new($self->baseurl);
        my $path = $url->path;
        return "$path";
}

has 'sftpobject' => (
        is => 'ro',
        required => 1,
        isa => 'Net::SSH2::SFTP',
);

has 'onhost_pathname' => (
        is => 'ro',
        isa => 'Str',
        lazy => 1,
        builder => '_probe_onhost_pathname',
);

sub _probe_onhost_pathname {
        my $self = shift;

        return join('/', $self->basepath, $self->relname);
}

sub _get_file {
        my $self = shift;
        my @parts = split('\.', $self->relname);
        my $ext = pop(@parts);
        my $dir = $self->workdir;

        if($self->has_data) {
                if($self->download_verbose) {
                        print "downloading " . $self->relname . " to " . $self->filename . "\n";
                }
                my ($fh, $file) = tempfile("sftp-XXXXXX", dir => $dir, SUFFIX => ".$ext");
                my $size = $self->sftpobject->stat($self->onhost_pathname)->{size};
                my $source = $self->sftpobject->open($self->onhost_pathname, O_RDONLY);
                while($size > 0) {
                        my $buf;
                        my $read = $source->read($buf, 32*1024);
                        if(defined($read)) {
                                syswrite($fh, $buf, $read);
                        } else {
                                $self->sftpobject->die_with_error('read error');
                        }
                        $size -= $read;
                }
                return $file;
        } else {
                my $file = join("/", $self->workdir, basename($self->relname));
                return $file;
        }
}

sub _probe_mtime {
        my $self = shift;
        my $mtime = $self->sftpobject->stat($self->onhost_pathname)->{mtime};
        return $mtime;
}

sub store_file {
        my $self = shift;
        return if(!$self->has_download);

        # auto flush
        local $| = 1;

        # Copy the file to the server. Algorithm taken straight from the
        # Net::SSH2::File documentation, so see there to understand what and
        # why.
        if($self->download_verbose) {
                print "uploading " . $self->filename . " to " . $self->onhost_pathname . " via sftp\n";
        }
        open my $fh, "<", $self->filename;
        my $dir = dirname($self->onhost_pathname);
        my @dirs;
        while(!$self->sftpobject->stat($dir)) {
                unshift @dirs, $dir;
                $dir = dirname($dir);
        }
        foreach $dir(@dirs) {
                $self->sftpobject->mkdir($dir);
        }
        my $sf = $self->sftpobject->open($self->onhost_pathname, O_WRONLY | O_CREAT | O_TRUNC);

        my $buf;
        while(sysread($fh, $buf, 32*1024)) {
                while(length($buf)) {
                        my $rc = $sf->write($buf);
                        if(!defined($rc)) {
                                $self->sftpobject->die_with_error('write error');
                        }
                        substr($buf, 0, $rc) = '';
                }
                if($self->download_verbose) {
                        print ".";
                }
        }
        return $self->SUPER::store_file;
}

sub delete {
        my $self = shift;
        $self->sftpobject->unlink($self->onhost_pathname);
}

no Moose;

1;
