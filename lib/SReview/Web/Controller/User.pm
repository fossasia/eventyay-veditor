package SReview::Web::Controller::User;

use Mojo::Base 'Mojolicious::Controller';
use SReview::API::Helpers;

sub add {
	my $c = shift->openapi->valid_input or return;

	my $user = $c->req->json;

	return add_with_json($c, $user, "users", $c->openapi->spec('/components/schemas/User/properties'));
}

sub update {
	my $c = shift->openapi->valid_input or return;

	my $userId = $c->param("userId");
	my $user = $c->req->json;

	$user->{id} = $userId;

	return update_with_json($c, $user, "users", $c->openapi->spec('/components/schemas/User/properties'));
}

sub getById {
	my $c = shift->openapi->valid_input or return;

	my $userId = $c->param('userId');

	my $user = db_query($c->dbh, "SELECT users.* FROM users WHERE id = ?", $userId);

	if(scalar(@$user) < 1) {
                $c->render(openapi => { errors => [ { message => "not found" } ]}, status => 404);
		return;
	}

	$c->render(openapi => $user->[0]);
}

sub delete {
	my $c = shift->openapi->valid_input or return;

	my $userId = $c->param('userId');

	return delete_with_query($c, "DELETE FROM users WHERE id = ?", $userId);
}

sub list {
	my $c = shift->openapi->valid_input or return;

	$c->render(openapi => db_query($c->dbh, "SELECT users.* FROM users"));
}

sub login {
        my $c = shift->openapi->valid_input or return;

        my $email = $c->param('email');
        my $pass = $c->param('pass');

        my $st = $c->dbh->prepare("SELECT id, isadmin, isvolunteer, name, room FROM users WHERE email=? AND password=crypt(?, password)");
        my $rv;
        if(!($rv = $st->execute($email, $pass))) {
                return $c->render(openapi => { errors => [ { message => "unknown user or password" } ] }, status => 403);
        }
        if($rv == 0) {
                return $c->render(openapi => { errors => [ { message => "unknown user or password" } ] }, status => 403);
        }
        if($st->rows < 1) {
                return $c->render(openapi => { errors => [ { message => "unknown user or password" } ] }, status => 403);
        }
        my $row = $st->fetchrow_arrayref;
        $c->session->{id} = $row->[0];
        $c->session->{email} = $email;
        $c->session->{admin} = $row->[1];
        $c->session->{volunteer} = $row->[2];
        $c->session->{name} = $row->[3];
        $c->session->{room} = $row->[4];

        my $json = {};

        if(!$c->session->{volunteer}) {
                my $apikey = random_string();
                $json->{apiKey} = $apikey;
                $c->session->{apikey} = $apikey;
        }
        return $c->render(openapi => $json);
}

sub logout {
        my $c = shift->openapi->valid_input or return;

        foreach my $field ("id", "email", "admin", "volunteer", "name", "room", "apikey") {
                delete $c->session->{$field};
        }

        return $c->render(openapi => "");
}

1;
