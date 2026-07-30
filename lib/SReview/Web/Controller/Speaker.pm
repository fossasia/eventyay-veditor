package SReview::Web::Controller::Speaker;

use Mojo::Base 'Mojolicious::Controller';
use SReview::API::Helpers;

sub listByTalk {
        my $c = shift->openapi->valid_input or return;

        my $eventId = $c->param("eventId");
        my $talkId = $c->param("talkId");

        my $talk = db_query($c->dbh, "SELECT id FROM talks WHERE event = ? AND id = ?", $eventId, $talkId);

        if(scalar(@$talk) < 1) {
                $c->render(openapi => { errors => [ { message => 'not found' } ] }, status => 404);
                return;
        }

        my $speakers = db_query($c->dbh, "SELECT speakers.* FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = ?", $talkId);

        $c->render(openapi => $speakers);
}

sub search {
        my $c = shift->openapi->valid_input or return;

        my $searchString = "%" . $c->param("searchString") . "%";

        $c->render(openapi => db_query($c->dbh, "SELECT speakers.* FROM speakers WHERE name ILIKE ? OR email ILIKE ?", $searchString, $searchString));
}

sub getByUpstream {
	my $c = shift->openapi->valid_input or return;

	my $speaker = db_query($c->dbh, "SELECT speakers.* FROM speakers WHERE upstreamid = ?", $c->param("upstreamId"));

	if(scalar(@$speaker) < 1) {
                $c->render(openapi => { errors => [ { message => 'not found' } ] }, status => 404);
		return;
	}

	$c->render(openapi => $speaker->[0]);
}

sub add {
        my $c = shift->openapi->valid_input or return;

        my $speaker = $c->req->json;
	$c->app->log->debug(join(',', keys %$speaker));

        return add_with_json($c, $speaker, "speakers", $c->openapi->spec('/components/schemas/Speaker/properties'));
}

sub update {
        my $c = shift->openapi->valid_input or return;

        my $speakerId = $c->param("speakerId");

        my $speaker = $c->req->json;

        $speaker->{id} = $speakerId;

        return update_with_json($c, $speaker, "speakers", $c->openapi->spec('/components/schemas/Speaker/properties'));
}

sub getById {
        my $c = shift->openapi->valid_input or return;

        my $speakerId = $c->param("speakerId");

        my $speaker = db_query($c->dbh, "SELECT speakers.* FROM speakers WHERE id = ?", $speakerId);

        if(scalar(@$speaker) < 1) {
                $c->render(openapi => { errors => [ { message => 'not found' } ] }, status => 404);
                return;
        }
        
        $c->render(openapi => $speaker->[0]);
}

sub delete {
        my $c = shift->openapi->valid_input or return;

        my $speakerId = $c->param('speakerId');

        return delete_with_query($c, "DELETE FROM speakers WHERE id = ?", $speakerId);
}

1;
