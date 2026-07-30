package SReview::Web::Controller::Talk;

use strict;
use warnings;

use feature "signatures";
no warnings "experimental::signatures";

use Mojo::Base 'Mojolicious::Controller';
use SReview::API::Helpers qw/db_query update_with_json add_with_json is_authed/;
use Mojo::Util 'slugify';
use Mojo::JSON qw/encode_json decode_json/;
use DateTime::Format::Pg;
use DateTime::Format::ISO8601;

use SReview::Talk;

sub format_talks($c, $talks) {
	foreach my $talk(@$talks) {
		$talk->{starttime} = DateTime::Format::ISO8601->format_datetime(DateTime::Format::Pg->parse_timestamptz($talk->{starttime}));
		$talk->{endtime} = DateTime::Format::ISO8601->format_datetime(DateTime::Format::Pg->parse_timestamptz($talk->{endtime}));
		if($talk->{flags}) {
			$talk->{flags} = decode_json($talk->{flags});
		}
                if(!is_authed($c)) {
                        delete($talk->{nonce});
                        delete($talk->{reviewer});
                        delete($talk->{comments});
                }
	}
	
	return $talks;
}

sub fixup {
	my $talk = shift;
	if($talk->{flags}) {
		$talk->{flags} = decode_json($talk->{flags});
	}
	return $talk;
}

sub listByEvent {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");

	my $event = db_query($c->dbh, "SELECT id FROM events WHERE id = ?", $eventId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'not found' } ] }, status => 404);
		return;
	}

	my $res = db_query($c->dbh, "SELECT talks.* FROM talks WHERE event = ?", $eventId);
	$res = format_talks($c, $res);

	$c->render(openapi => $res);
}

sub talksByState {
        my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");
	my $state = $c->param("state");

	my $event = db_query($c->dbh, "SELECT id FROM events WHERE id = ?", $eventId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'not found' } ] }, status => 404);
		return;
	}

	my $res = db_query($c->dbh, "SELECT talks.* FROM talks WHERE event = ? AND state = ?", $eventId, $state);
	$res = format_talks($c, $res);

	$c->render(openapi => $res);
}

sub add {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");

	my $event = db_query($c->dbh, "SELECT id FROM events WHERE id = ?", $eventId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'Event not found' } ] }, status => 404);
		return;
	}

	my $talk = $c->req->json;
	$talk->{event} = $event->[0];
	if(!exists($talk->{slug})) {
		$talk->{slug} = slugify($talk->{title});
	}

	return add_with_json($c, $talk, "talks", $c->openapi->spec('/components/schemas/Talk/properties'), \&fixup);
}

sub update {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param('eventId');
	my $talkId = $c->param('talkId');

	my $talk_check = db_query($c->dbh, "SELECT id FROM talks WHERE id = ? AND event = ?", $talkId, $eventId);

	if(scalar(@$talk_check) < 1) {
                $c->render(openapi => { errors => [ { message => 'Talk not found in given event' } ] }, status => 404);
		return;
	}

	my $talk = $c->req->json;

	$talk->{id} = $talkId;

	if(exists($talk->{flags})) {
		$talk->{flags} = encode_json($talk->{flags});
	}

	return update_with_json($c, $talk, "talks", $c->openapi->spec('/components/schemas/Talk/properties'), \&fixup);
}

sub delete {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param('eventId');
	my $talkId = $c->param('talkId');

	my $event = db_query($c->dbh, "SELECT id FROM events WHERE id = ?", $eventId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'Event not found' } ] }, status => 404);
		return;
	}

	return delete_with_query($c, 'DELETE FROM talks WHERE id = ? AND event = ?', $talkId, $eventId);
}

sub setSpeakers {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param('eventId');
	my $talkId = $c->param('talkId');

	my $event = db_query($c->dbh, "SELECT id FROM talks WHERE id = ? AND event = ?", $talkId, $eventId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'Event or talk not found' } ] }, status => 404);
		return;
	}

	my $speakers = $c->req->json;
	my $dbh = $c->dbh;

	$dbh->begin_work();

	db_query($dbh, 'DELETE FROM speakers_talks WHERE talk = ? RETURNING talk', $talkId);

	if(scalar(@$speakers) < 1) {
		$c->render(openapi => []);
		$dbh->commit;
		return;
	}

	foreach my $speakerId(@$speakers) {
		my $speaker = db_query($dbh, 'SELECT id FROM speakers WHERE id = ?', $speakerId);
		if(scalar(@$speaker) < 1) {
                        $c->render(openapi => { errors => [ { message => 'Speaker not found' } ] }, status => 404);
			$dbh->rollback;
			return;
		}
		db_query($dbh, 'INSERT INTO speakers_talks(speaker, talk) VALUES(?, ?) RETURNING speaker', $speakerId, $talkId);
		if($dbh->err) {
                        $c->render(openapi => { errors => [ { message => 'Could not add speaker:' . $dbh->errmsg } ] }, status => 400);
			$dbh->rollback;
			return;
		}
	}

	$dbh->commit;

	$speakers = db_query($dbh, "SELECT speaker FROM speakers_talks WHERE talk = ?", $talkId);

	return $c->render(openapi => $speakers);
}

sub addSpeakers {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param('eventId');
	my $talkId = $c->param('talkId');

	my $event = db_query($c->dbh, "SELECT id FROM talks WHERE event = ? AND id = ?", $eventId, $talkId);

	if(scalar(@$event) < 1) {
                $c->render(openapi => { errors => [ { message => 'Event or talk not found' } ] }, status => 404);
		return;
	}

	my $speakers = $c->req->json;

	if(scalar(@$speakers) < 1) {
                $c->render(openapi => { errors => [ { message => 'at least one speaker is required' } ] }, status => 400);
		return;
	}
	my $dbh = $c->dbh;

	$dbh->begin_work;

	foreach my $speakerId(@$speakers) {
		my $speaker = db_query($dbh, 'SELECT id FROM speakers WHERE id = ?', $speakerId);
		if(scalar(@$speaker) < 1) {
                        $c->render(openapi => { errors => [ { message => 'Speaker not found' } ] }, status => 404);
			$dbh->rollback;
			return;
		}
		eval {
			db_query($dbh, 'INSERT INTO speakers_talks(speaker, talk) VALUES(?, ?) RETURNING speaker', $speakerId, $talkId);
		};
		if($@ && $dbh->err) {
                        $c->render(openapi => { errors => [ { message => 'Could not add speaker:' . $dbh->errstr } ] }, status => 400);
			$dbh->rollback;
			return;
		}
	}

	$dbh->commit;

	$speakers = db_query($dbh, "SELECT speaker FROM speakers_talks WHERE talk = ?", $talkId);

	return $c->render(openapi => $speakers);
}

sub getById {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");
	my $talkId = $c->param("talkId");

	my $talk = db_query($c->dbh, "SELECT talks.* FROM talks WHERE event = ? AND id = ?", $eventId, $talkId);

	if(scalar(@$talk) < 1) {
                $c->render(openapi => { errors => [ { message => "Event or talk not found" } ] }, status => 404);
		return;
	}

	$c->render(openapi => format_talks($c, $talk)->[0]);
}

sub getByNonce {
	my $c = shift->openapi->valid_input or return;

	my $nonce = $c->param("nonce");

	my $talk = db_query($c->dbh, "SELECT talks.* FROM talks WHERE nonce = ?", $nonce);

	if(scalar(@$talk) < 1) {
                $c->render(openapi => { errors => [ { message => "not found" } ] }, status => 404);
		return;
	}
	$c->render(openapi => format_talks($c, $talk)->[0]);
}

sub getCorrections {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");
	my $talkId = $c->param("talkId");

	my $talk = db_query($c->dbh, "SELECT id FROM talks WHERE event = ? AND id = ?", $eventId, $talkId);

	if(scalar(@$talk) < 1) {
                $c->render(openapi => { errors => [ { message => "event or talk not found" } ] }, status => 404);
		return;
	}

	$talk = SReview::Talk->new(talkid => $talkId);

	$c->render(openapi => $talk->corrections);
}

sub getRelativeName {
	my $c = shift->openapi->valid_input or return;

	my $eventId = $c->param("eventId");
	my $talkId = $c->param("talkId");

	my $talk = db_query($c->dbh, "SELECT id FROM talks WHERE event = ? AND id = ?", $eventId, $talkId);

	if(scalar(@$talk) < 1) {
                $c->render(openapi => { errors => [ { message => "event or talk not found" } ] }, status => 404);
		return;
	}

	$talk = SReview::Talk->new(talkid => $talkId);

	$c->render(openapi => $talk->relative_name);
}

1;
