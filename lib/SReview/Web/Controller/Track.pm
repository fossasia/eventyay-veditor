package SReview::Web::Controller::Track;

use Mojo::Base 'Mojolicious::Controller';
use SReview::API::Helpers;

sub add {
        my $c = shift->openapi->valid_input or return;

        my $track = $c->req->json;

        return add_with_json($c, $track, "tracks", $c->openapi->spec('/components/schemas/Track/properties'));
}

sub update {
        my $c = shift->openapi->valid_input or return;

        my $track = $c->req->json;
        my $trackId = $c->param('trackId');

        $track->{id} = $trackId;

        return update_with_json($c, $track, "tracks", $c->openapi->spec('/components/schemas/Track/properties'));
}

sub list {
        my $c = shift->openapi->valid_input or return;

        $c->render(openapi => db_query($c->dbh, "SELECT tracks.* FROM tracks"));
}

sub getById {
        my $c = shift->openapi->valid_input or return;

        my $trackId = $c->param('trackId');

        my $track = db_query($c->dbh, "SELECT tracks.* FROM tracks WHERE id = ?", $trackId);

        if(scalar(@$track) < 1) {
                $c->render(openapi => { errors => [ { message => "not found" } ]}, status => 404);
                return;
        }

        $c->render(openapi => $track->[0]);
}

sub delete {
        my $c = shift->openapi->valid_input or return;
        
        my $trackId = $c->param("trackId");

        return delete_with_query($c, "DELETE FROM tracks WHERE id = ?", $trackId);
}

1;
