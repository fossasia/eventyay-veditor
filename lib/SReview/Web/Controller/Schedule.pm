package SReview::Web::Controller::Schedule;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Log;

sub talks {
	my $self = shift;

	my $db = $self->dbh;

	my $eventdata = $db->prepare("SELECT * FROM talk_list WHERE eventid = ? ORDER BY id");
	$eventdata->execute($self->eventid());

	$self->app->log->debug("finding talks for event " . $self->eventid());

	my $rv = ();

	while(my $row = $eventdata->fetchrow_hashref()) {
		$self->app->log->debug("found talk with id: " . $row->{id});
		push @$rv, $row;
	}

	$self->render(json => $rv);
}

sub index { }

1;

__DATA__
@@ schedule/index.html.ep
% layout 'admin'
<h1>Schedule management</h1>
<p>Possible actions:</p>
<dl><dt>GET /admin/schedule/list</dt>
<dd>Creates a JSON list of all talks in the current event</dd>
<dt>DELETE /admin/schedule/talk/:id</dt>
<dd>Delete the talk with the given ID</dd>
<dt>PUT /admin/schedule/talk/</dt>
<dd>Create a new talk (requires JSON object)</dd>
<dt>PUT /admin/schedule/talk/:id</dt>
<dd>Update the data of the talk with the given ID</dd>
