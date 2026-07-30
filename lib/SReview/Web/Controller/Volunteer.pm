package SReview::Web::Controller::Volunteer;

use Mojo::Base 'Mojolicious::Controller';

sub list {
	my $c = shift;
	my @talks;
	$c->dbh->begin_work;
	my $already = $c->dbh->prepare("SELECT nonce, title, id, state FROM talks WHERE reviewer = ? AND state <= 'preview'");
	my $new = $c->dbh->prepare("SELECT nonce, title, id, state FROM talks WHERE reviewer IS NULL AND state = 'preview'::talkstate LIMIT ? FOR UPDATE");
	my $claim = $c->dbh->prepare("UPDATE talks SET reviewer = ? WHERE id = ?");
	$already->execute($c->session->{id});
	my $count = $already->rows;
	if($count < 5) {
		$new->execute(5 - $count);
	}
	for(my $i = 0; $i < $count; $i++) {
		my $row = [ $already->fetchrow_array ];
		push @talks, $row;
	}
	for(my $i = 0; $i < $new->rows; $i++) {
		my $row = [ $new->fetchrow_array ];
		$claim->execute($c->session->{id}, $row->[2]);
		push @talks, $row;
	}
	$c->stash(talks => \@talks);
	$c->stash(layout => 'admin');
	$c->dbh->commit;
}

1;
