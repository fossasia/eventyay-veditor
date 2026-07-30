package SReview::API::Helpers;

use strict;
use warnings;

use feature "signatures";
no warnings "experimental::signatures";

use Exporter 'import';
our @EXPORT = qw/db_query update_with_json add_with_json delete_with_query/;
our @EXPORT_OK = qw/db_query_log is_authed/;

use SReview::Config::Common;
use Mojo::JSON qw/decode_json encode_json/;
use DateTime::Format::Pg;

sub db_query_log {
	my ($app, $dbh, $query, @args) = @_;
	my $st = $dbh->prepare($query);
	$st->execute(@args);
	my $results = [];
	while(my @row = $st->fetchrow_array) {
		if(scalar(@row) > 1) {
			my $h = {};
			foreach my $col(@{$st->{NAME_lc}}) {
				$h->{$col} = shift @row;
			}
			push @$results, $h;
		} else {
			push @$results, @row;
		}
	}
	return $results;
}

sub db_query {
	my ($dbh, $query, @args) = @_;

	return db_query_log(undef, $dbh, $query, @args);
}

sub delete_with_query {
	my ($c, $query, @args) = @_;

	my $st = $c->dbh->prepare($query);
	eval {
		$st->execute(@args);
	};

	if($st->err) {
		$c->render(openapi => {errors => [{message => 'could not delete:', $st->errmsg}]}, status => 400);
		return;
	}

	if($st->rows < 1) {
		$c->render(openapi => {errors => [{message => 'not found'}]}, status => 404);
		return;
	}
	my $row = $st->fetchrow_arrayref;
	$c->render(openapi => $row->[0]);
}

sub update_with_json {
	my ($c, $json, $tablename, $fields, $fixup) = @_;

	my @args;

	if(!exists($json->{id})) {
		$c->render(openapi => {errors => [{message => 'id required'}]}, status => 400);
		return;
	}

	$c->app->log->debug("updating $tablename with " . encode_json($json));

	my @updates;

	while(my @tuple = each %$json) {
		if($tuple[0] eq "id") {
			$c->app->log->debug("skipping id");
			next;
		}
		unless(exists($fields->{$tuple[0]})) {
			$c->app->log->debug("skipping unknown field " . $tuple[0]);
			next;
		}
		my $update = $tuple[0] . " = ?";
		push @updates, $update;
		push @args, $tuple[1];
	}
	my $updates = join(', ', @updates);
	my $dbh = $c->dbh;
	my $res;
	my $query = "UPDATE $tablename SET $updates WHERE id = ? RETURNING $tablename.*";
	eval {
		$res = db_query($dbh, $query ,@args, $json->{id});
	};
	if($@) {
		$c->app->log->warn("error running $query: " . $dbh->errstr);
		$c->render(openapi => {errors => [{message => "error communicating with database"}]}, status => 500);
		return;
	}

	if(scalar(@$res) < 1) {
		$c->render(openapi => {errors => [{message => "not found"}]}, status => 404);
		return;
	}
	my $result = $res->[0];
	foreach my $field(keys %$fields) {
		next unless exists($fields->{$field}{format});
		if($fields->{$field}{format} eq "date-time") {
			# PostgreSQL never uses the T in date-time
			# fields unless we're encoding JSON. Doing that
			# makes Mojo::JSON unhappy. Not doing that makes
			# OpenAPI unhappy about the lack of the T.
			#
                        # JSON makes me unhappy.
                        $c->app->log->debug("changing date; before: ");
                        $c->app->log->debug($result->{$field});
			$result->{$field} = DateTime::Format::Pg->parse_datetime($result->{$field})->iso8601() or die;
                        $c->app->log->debug("after: " . $result->{$field});
		}
	}
	if(defined($fixup)) {
		&$fixup($res->[0]);
	}

	$c->render(openapi => $res->[0]);
}

sub add_with_json {
	my ($c, $json, $tablename, $fields, $fixup) = @_;

	my @args;
	my @inserts;

	if(exists($json->{id})) {
		delete $json->{id};
	}

	while(my @tuple = each %$json) {
		next if($tuple[0] eq "id");
		next unless(exists($fields->{$tuple[0]}));
		push @inserts, $tuple[0];
		push @args, $tuple[1];
	}

	my $inserts = join(', ', @inserts);
	my $fieldlist;
	if(scalar(@inserts) > 0) {
		$fieldlist = "?, " x (scalar(@inserts) - 1) . "?";
	} else {
		$fieldlist = "";
	}
	my $dbh = $c->dbh;
	my $res;
	eval {
		$res = db_query($dbh, "INSERT INTO $tablename($inserts) VALUES($fieldlist) RETURNING $tablename.*", @args);
	};

	if(!defined($res) || scalar(@$res) < 1) {
		$c->render(openapi => {errors => [{message => "failed to add data: " . $dbh->errstr}]}, status => 400);
		return;
	}
	my $result = $res->[0];
	foreach my $field(keys %$fields) {
		next unless exists($fields->{$field}{format});
		if($fields->{$field}{format} eq "date-time") {
			# PostgreSQL never uses the T in date-time
			# fields unless we're encoding JSON. Doing that
			# makes Mojo::JSON unhappy. Not doing that makes
			# OpenAPI unhappy about the lack of the T.
			#
                        # JSON makes me unhappy.
                        $c->app->log->debug("changing date; before: ");
                        $c->app->log->debug($result->{$field});
			$result->{$field} = DateTime::Format::Pg->parse_datetime($result->{$field})->iso8601() or die;
                        $c->app->log->debug("after: " . $result->{$field});
		}
	}
	if(defined($fixup)) {
		&$fixup($res->[0]);
	}

	$c->render(openapi => $res->[0]);
}

sub is_authed($c) {
	return defined($c->req->headers->header("X-SReview-Key"));
}
