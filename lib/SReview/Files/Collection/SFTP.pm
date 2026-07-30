package SReview::Files::Collection::SFTP;

use Moose;
use Net::SSH2;
use Mojo::URL;
use Carp;
use Fcntl ':mode';
use SReview::Files::Access::SFTP;

extends 'SReview::Files::Collection::Net';

has 'sftpobject' => (
        is => 'ro',
        isa => 'Net::SSH2::SFTP',
        lazy => 1,
        builder => '_probe_sftpobj',
);

has '+fileclass' => (
        default => 'SReview::Files::Access::SFTP',
);

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

sub _probe_sftpobj {
        my $self = shift;
        my $ssh = Net::SSH2->new();
        my $config = SReview::Config::Common::setup();

        my $url = Mojo::URL->new($self->baseurl);
        $ssh->connect($url->host);
        my $sshconf = $config->get('sftp_access_config');
        croak("SFTP access method requires sftp_access_config to be set!") unless defined $sshconf;
        if(exists($sshconf->{$url->host})) {
                $ssh->auth(%{$sshconf->{$url->host}});
        } elsif(exists($sshconf->{default})) {
                $ssh->auth(%{$sshconf->{default}});
        } else {
                croak('SFTP access method requires authentication configuration to be set in $sftp_access_config->{' . $url->host . "}!");
        }
        if(!$ssh->auth_ok) {
                croak("Could not manage files using SFTP: authentication failure");
        }
        return $ssh->sftp();
}

sub _probe_children {
        my $self = shift;
        my $return = [];
        my $baseurl;

        eval {
                my $dir = $self->sftpobject->opendir($self->basepath);
                while(my $file = $dir->read) {
                        next if($file->{name} eq '.');
                        next if($file->{name} eq '..');
                        if(S_ISDIR($file->{mode})) {
                                eval {
                                        push @$return, @{SReview::Files::Collection::SFTP->new(baseurl => $self->baseurl . "/" . $file->{name}, sftpobject => $self->sftpobject, download_verbose => $self->download_verbose)->children};
                                };
                                if($@) {
                                        if($@->isa("Moose::Exception::ValidationFailedForInlineTypeConstraint")) {
                                                next;
                                        }
                                        die $@;
                                }
                        } else {
                                push @$return, SReview::Files::Access::SFTP->new(baseurl => $self->baseurl, relname => $file->{name}, sftpobject => $self->sftpobject, download_verbose => $self->download_verbose);
                        }
                }
        };
        if($@) {
                croak("Could not read directory " . $self->basepath . ": $@");
        }
        return $return;
}

sub has_file {
        my ($self, $target) = @_;
        return defined($self->sftpobject->stat(join('/', $self->basepath, $target)));
}

sub _create {
        my $self = shift;
        my %options = @_;

        $options{sftpobject} = $self->sftpobject;

        return $self->SUPER::_create(%options);
}

no Moose;

1;
