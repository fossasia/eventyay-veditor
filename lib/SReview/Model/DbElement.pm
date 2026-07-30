package SReview::Model::DbElement;

use Moose;

use SReview::Config::Common;
use SReview::Db;

has 'config' => (
	is => 'rw',
	isa => 'SReview::Config',
	builder => '_get_config',
	lazy => 1,
);

sub _get_config {
	my $self = shift;
	return SReview::Config::Common::setup;
}

has 'dbh' => (
	is => 'rw',
	isa => 'Mojo::Pg',
	builder => '_get_dbh',
	lazy => 1,
);

sub _get_dbh {
	my $self = shift;
	my $pg = Mojo::Pg->new()->dsn($self->config->get('dbistring'));
}

no Moose;

1;
