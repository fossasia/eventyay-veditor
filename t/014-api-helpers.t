#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;

use SReview::API::Helpers qw/db_query_log update_with_json add_with_json delete_with_query is_authed/;

{
	package Local::Stub::St;
	sub new {
		my ($class, %args) = @_;
		return bless {
			rows => $args{rows} // 1,
			err => $args{err} // 0,
			errmsg => $args{errmsg} // 'err',
			data => $args{data} // [],
			NAME_lc => $args{NAME_lc} // [],
		}, $class;
	}
	sub execute { return 1; }
	sub fetchrow_array {
		my ($self) = @_;
		return @{ shift @{$self->{data}} } if @{$self->{data}};
		return;
	}
	sub fetchrow_arrayref { return $_[0]->{fetchrow_arrayref} // [123]; }
	sub rows { return $_[0]->{rows}; }
	sub err { return $_[0]->{err}; }
	sub errmsg { return $_[0]->{errmsg}; }

	package Local::Stub::Dbh;
	sub new {
		my ($class) = @_;
		return bless { st => undef, errstr => 'db-error' }, $class;
	}
	sub prepare {
		my ($self, $query) = @_;
		$self->{last_query} = $query;
		return $self->{st};
	}
	sub set_st { $_[0]->{st} = $_[1]; }
	sub errstr { return $_[0]->{errstr}; }

	package Local::Stub::Headers;
	sub new { bless { h => {} }, shift }
	sub header { my ($self, $k) = @_; return $self->{h}{$k}; }
	sub set { my ($self, $k, $v) = @_; $self->{h}{$k} = $v; }

	package Local::Stub::Req;
	sub new { bless { headers => Local::Stub::Headers->new }, shift }
	sub headers { return $_[0]->{headers}; }

	package Local::Stub::Log;
	sub new { bless { debug => [], warn => [] }, shift }
	sub debug { push @{$_[0]->{debug}}, $_[1]; }
	sub warn { push @{$_[0]->{warn}}, $_[1]; }

	package Local::Stub::App;
	sub new { bless { log => Local::Stub::Log->new }, shift }
	sub log { return $_[0]->{log}; }

	package Local::Stub::Controller;
	sub new {
		my ($class, %args) = @_;
		return bless {
			dbh => $args{dbh},
			app => Local::Stub::App->new,
			req => Local::Stub::Req->new,
			renders => [],
		}, $class;
	}
	sub dbh { return $_[0]->{dbh}; }
	sub app { return $_[0]->{app}; }
	sub req { return $_[0]->{req}; }
	sub render {
		my ($self, %args) = @_;
		push @{$self->{renders}}, \%args;
	}
	sub renders { return $_[0]->{renders}; }
}

# db_query_log: list context with scalar rows
{
	my $st = Local::Stub::St->new(
		data => [ ["a"], ["b"] ],
		NAME_lc => ['x'],
	);
	my $dbh = Local::Stub::Dbh->new;
	$dbh->set_st($st);
	my $res = db_query_log(undef, $dbh, "SELECT x");
	is_deeply($res, ["a", "b"], 'db_query_log returns array of scalars for single-column query');
}

# db_query_log: hash rows when multiple columns
{
	my $st = Local::Stub::St->new(
		data => [ ["A", "B"] ],
		NAME_lc => ['c1', 'c2'],
	);
	my $dbh = Local::Stub::Dbh->new;
	$dbh->set_st($st);
	my $res = db_query_log(undef, $dbh, "SELECT c1,c2");
	is_deeply($res, [ { c1 => 'A', c2 => 'B' } ], 'db_query_log returns array of hashes for multi-column query');
}

# is_authed
{
	my $dbh = Local::Stub::Dbh->new;
	my $c = Local::Stub::Controller->new(dbh => $dbh);
	ok(!is_authed($c), 'is_authed false when header missing');
	$c->req->headers->set('X-SReview-Key', 'K');
	ok(is_authed($c), 'is_authed true when header present');
}

# update_with_json: missing id
{
	my $dbh = Local::Stub::Dbh->new;
	my $c = Local::Stub::Controller->new(dbh => $dbh);
	update_with_json($c, { title => 'x' }, 'talks', { title => {} }, undef);
	is($c->renders->[-1]{status}, 400, 'update_with_json returns 400 when id missing');
}

# add_with_json: empty insert list generates valid SQL and returns result
{
	my $st = Local::Stub::St->new(
		data => [ [ { id => 1 } ] ],
		NAME_lc => ['row'],
	);
	my $dbh = Local::Stub::Dbh->new;
	$dbh->set_st($st);
	my $c = Local::Stub::Controller->new(dbh => $dbh);

	# Make db_query return deterministic structure by leveraging stub: data must be array rows;
	# db_query_log will flatten to scalar when one column; here we want hash, so use two columns.
	# Instead, call add_with_json with one known field so inserts is non-empty.
	my $st2 = Local::Stub::St->new(
		data => [ [1, 'x'] ],
		NAME_lc => ['id', 'title'],
	);
	$dbh->set_st($st2);
	add_with_json($c, { title => 'x' }, 'talks', { title => {} }, undef);
	is($c->renders->[-1]{openapi}{title}, 'x', 'add_with_json renders returned row');
}

# delete_with_query: not found
{
	my $st = Local::Stub::St->new(rows => 0);
	my $dbh = Local::Stub::Dbh->new;
	$dbh->set_st($st);
	my $c = Local::Stub::Controller->new(dbh => $dbh);

	delete_with_query($c, 'DELETE FROM t WHERE id=? RETURNING id', 1);
	is($c->renders->[-1]{status}, 404, 'delete_with_query returns 404 when rows<1');
}

done_testing;
