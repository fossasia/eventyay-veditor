package SReview::Web::Controller::Admin;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Collection 'c';

sub main {
	my $c = shift;
	my $st;
	my $talks = ();
	my $room;
	my $lastroom = '';

	if(defined($c->session->{room})) {
		$st = $c->dbh->prepare('SELECT nonce, room, name, starttime, speakers, state FROM talk_list WHERE eventid = ? AND roomid = ? ORDER BY starttime');
		$st->execute($c->eventid, $c->session->{room});
	} else {
		$st = $c->dbh->prepare('SELECT nonce, room, name, starttime, speakers, state FROM talk_list WHERE eventid = ? ORDER BY room, starttime');
		$st->execute($c->eventid);
	}
	while(my $row = $st->fetchrow_hashref("NAME_lc")) {
		if ($row->{'room'} ne $lastroom) {
			if(defined($room)) {
				push @$talks, c($lastroom => $room);
			}
			$room = [];
		}
		$lastroom = $row->{'room'};
		next unless defined($row->{nonce});
		push @$room, [$row->{'starttime'} . ': ' . $row->{'name'} . ' by ' . $row->{'speakers'} . ' (' . $row->{'state'} . ')' => $row->{'nonce'}];
	}
	if(defined($room)) {
		push @$talks, c($lastroom => $room);
	}
	$c->stash(email => $c->session->{email});
	$c->stash(talks => $talks);
	$c->render;
}

1;
