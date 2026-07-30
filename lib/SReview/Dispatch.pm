package SReview::Dispatch;

use strict;
use warnings;

use Mojo::JSON qw/encode_json true/;

sub pending_talks {
	my ($dbh, $config, $state_actions) = @_;

	my $statelist = join(",", map { $dbh->quote($_) } keys(%{$state_actions}));

	my @where = ("state IN ($statelist)", "progress = 'waiting'", "events.name = ?");
	my @bind = ($config->get('event'));

	my $require_flags = $config->get('dispatch_require_flags');
	if(defined($require_flags) && ref($require_flags) eq 'ARRAY' && scalar(@{$require_flags}) > 0) {
		my %obj = map { $_ => true } @{$require_flags};
		push @where, "COALESCE(talks.flags, '{}'::jsonb) \@> ?::jsonb";
		push @bind, encode_json(\%obj);
	}

	my $ignore_flags = $config->get('dispatch_ignore_flags');
	if(defined($ignore_flags) && ref($ignore_flags) eq 'ARRAY' && scalar(@{$ignore_flags}) > 0) {
		for my $flag (@{$ignore_flags}) {
			my %obj = ($flag => true);
			push @where, "NOT (COALESCE(talks.flags, '{}'::jsonb) \@> ?::jsonb)";
			push @bind, encode_json(\%obj);
		}
	}

	my $sql = "SELECT talks.id, state, progress, title, rooms.name AS room, extract(epoch from (endtime - starttime)) AS length " .
		"FROM talks JOIN rooms ON rooms.id = talks.room JOIN events ON events.id = talks.event WHERE (" . join(" AND ", @where) . ")";

	if($config->get('query_limit') > 0) {
		$sql .= " LIMIT ?";
		push @bind, $config->get('query_limit');
	}

	my $st = $dbh->prepare($sql);
	$st->execute(@bind);

	my @rows;
	while(my $row = $st->fetchrow_hashref) {
		push @rows, $row;
	}

	return \@rows;
}

1;
