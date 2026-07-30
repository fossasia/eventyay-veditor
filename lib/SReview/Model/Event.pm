package SReview::Model::Event;

use Moose;

extends 'SReview::Model::DbElement';

has 'name' => (
	is => 'ro',
	builder => '_get_name',
);

sub _get_name {
	return shift->config->get('event');
}

has 'inputdir' => (
	is => 'ro',
	builder => '_get_inputdir',
	lazy => 1,
);

sub _get_inputdir {
	my $self = shift;
	my $st = $self->dbh->db->dbh->prepare("SELECT inputdir FROM events WHERE name = ?");
	$st->execute($self->name);
	if($st->rows == 0) {
		return $self->name;
	}
	my $dir = $st->fetchrow_hashref()->{inputdir};
	if(!defined($dir)) {
		return $self->name;
	}
	return $dir;
}

no Moose;

1;
