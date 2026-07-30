package SReview::Files::Collection::HTTP::nginx::JSON;

use Moose;
use Mojo::UserAgent;
use DateTime::Format::Strptime;

extends 'SReview::Files::Collection::HTTP';

sub _probe_children {
	my $self = shift;
	my $ua = Mojo::UserAgent->new;
	my $baseurl = $self->baseurl;
	my $parser = DateTime::Format::Strptime->new(
		pattern => '%a, %d %b %Y %H:%M:%S %Z',
		locale => 'C',
		on_error => 'croak'
	);
	if(substr($baseurl, -1) ne "/") {
		$baseurl .= "/";
	}
	my $return = [];
	my $res = $ua->get($baseurl)->result;
	if($res->is_success) {
		foreach my $obj(@{$res->json}) {
			if($obj->{type} eq "directory") {
				foreach my $child(@{SReview::Files::Collection::HTTP::nginx::JSON->new(baseurl => join("/", $self->baseurl, $obj->{name}), download_verbose => $self->download_verbose)->children}) {
					push @$return, SReview::Files::Access::HTTP->new(baseurl => $self->baseurl, relname => join('/', $obj->{name}, $child->{relname}), mtime => $child->mtime);
				}
			} else {
				push @$return, SReview::Files::Access::HTTP->new(baseurl => $self->baseurl, relname => $obj->{name}, mtime => $parser->parse_datetime($obj->{mtime}), download_verbose => $self->download_verbose);
			}
		}
	}

	return $return;
}
