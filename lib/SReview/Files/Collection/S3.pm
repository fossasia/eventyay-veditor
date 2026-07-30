package SReview::Files::Collection::S3;

use Moose;
use Net::Amazon::S3;
use DateTime::Format::ISO8601;
use SReview::Config::Common;
use SReview::Files::Access::S3;

extends "SReview::Files::Collection::Net";

has 's3object' => (
	is => 'ro',
	isa => 'Net::Amazon::S3::Bucket',
	lazy => 1,
	builder => '_probe_s3obj',
);

has '+fileclass' => (
	default => 'SReview::Files::Access::S3',
);

sub _probe_s3obj {
	my $self = shift;
	my $config = SReview::Config::Common::setup();
	my $bucket;
	if($self->has_baseurl) {
		$bucket = $self->baseurl;
	} else {
		my @elements = split('\/', $self->globpattern);
		do {
			$bucket = shift(@elements)
		} while(!length($bucket));
		$self->_set_baseurl($bucket);
	}
	my $aconf = $config->get('s3_access_config');
	if(exists($aconf->{$bucket})) {
		$aconf = $aconf->{$bucket};
	} else {
		if(!exists($aconf->{default})) {
			croak("S3 access configuration does not exist for $bucket, nor does a default exist");
		}
		$aconf = $aconf->{default};
	}
	return Net::Amazon::S3->new($aconf)->bucket($bucket);
}

sub _probe_children {
	my $self = shift;
	my $return = [];
	my $baseurl;

	eval {
		foreach my $key(@{$self->s3object->list_all->{keys}}) {
			push @$return, SReview::Files::Access::S3->new(
				s3object => $self->s3object,
				baseurl => $self->baseurl,
				mtime => DateTime::Format::ISO8601->parse_datetime($key->{last_modified}),
				relname => $key->{key},
                                download_verbose => $self->download_verbose
			);
		}
	};
	return $return;
}

sub _create {
	my $self = shift;
	my %options = @_;

	$options{s3object} = $self->s3object;

	return $self->SUPER::_create(%options);
}

no Moose;

1;
