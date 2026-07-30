package SReview::Web::Controller::Room;

use Mojo::Base 'Mojolicious::Controller';
use SReview::API::Helpers;

sub add {
        my $c = shift->openapi->valid_input or return;

        my $room = $c->req->json;

        return add_with_json($c, $room, "rooms", $c->openapi->spec('/components/schemas/Room/properties'));
}

sub update {
        my $c = shift->openapi->valid_input or return;

        my $roomId = $c->param('roomId');
        my $room = $c->req->json;

        $room->{id} = $roomId;

        return update_with_json($c, $room, "rooms", $c->openapi->spec('/components/schemas/Room/properties'));
}

sub getById {
        my $c = shift->openapi->valid_input or return;

        my $roomId = $c->param('roomId');

        my $room = db_query($c->dbh, "SELECT rooms.* FROM rooms WHERE id = ?", $roomId);

        if(scalar(@$room) < 1) {
                $c->render(openapi => { errors => [ { message => "not found" } ]}, status => 404);
                return;
        }

        $c->render(openapi => $room->[0]);
}

sub delete {
        my $c = shift->openapi->valid_input or return;

        my $roomId = $c->param("roomId");

        return delete_with_query($c, "DELETE FROM rooms WHERE id = ? RETURNING id", $roomId);
}

sub list {
        my $c = shift->openapi->valid_input or return;

        my $rooms = db_query($c->dbh, "SELECT rooms.* FROM rooms");

        $c->render(openapi => $rooms);
}

1;
