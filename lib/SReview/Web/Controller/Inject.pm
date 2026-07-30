package SReview::Web::Controller::Inject;

use Media::Convert::Asset;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Collection 'c';
use File::Basename "dirname";

use SReview::Access "admin_for";
use SReview::Files::Factory;
use SReview::Talk;

sub view {
	my $c = shift;

	my $talk;
	my $id = $c->stash("id");
	eval {
		if(defined($id)) {
			$talk = SReview::Talk->new(talkid => $id);
		} else {
			$talk = SReview::Talk->by_nonce($c->stash("nonce"));
		}
	};
	if($@) {
		$c->stash(error => $@);
		$c->stash(short_error => "Exception occurred");
		$c->render(variant => 'error');
		return;
	}

	my $nonce = $talk->nonce;
	my $variant;
	$c->stash(adminspecial => 0);
	if ($talk->state <= 'preview') {
		$variant = undef;
	} elsif(admin_for($c, $talk)) {
		$variant = undef;
		$c->stash(adminspecial => 1);
	} elsif(!$talk->get_flag("can_inject")) {
		$variant = 'error';
		$c->stash(short_error => "Injection not allowed for this talk");
		$c->stash(error => "Talks can only be injected when an administrator enables the option for that talk. Please talk to the administrators of the review system and ask them to enable this option for this talk.");
	} else  {
		$variant = 'done';
	}

	my $vid_prefix = $c->srconfig->get('vid_prefix');
	$vid_prefix = '' unless defined($vid_prefix);
	$c->stash(vid_prefix => $vid_prefix);

	$c->stash(talk => $talk);
	$c->stash(stylesheets => ['/review.css']);
	$c->stash(variant => $variant);
}

sub update {
	my $c = shift;
	my $id = $c->stash("id");
	my $talk;

	$c->stash(stylesheets => ['/review.css']);
	if(defined($id)) {
		$talk = SReview::Talk->new(talkid => $id);
	} else {
		eval {
			$talk = SReview::Talk->by_nonce($c->stash('nonce'));
		};
		if($@) {
			$c->stash(error => $@);
			$c->stash(short_error => 'Exception occurred');
			$c->render(variant => 'error');
			return;
		}
	}
	$c->stash(talk => $talk);
	if(!admin_for($c, $talk) && $talk->state > 'preview' && $talk->state != 'injecting') {
		$c->stash(short_error => 'Not available');
		$c->stash(error => 'This talk is not currently available for data injection. Please try again later!');
		$c->render(variant => 'error');
		return;
	}
	my $collname = $c->srconfig->get("inject_collection");
	foreach my $upload(@{$c->req->uploads}) {
		if($upload->name eq "video_asset") {
			next unless defined($upload->filename) && length($upload->filename) > 0;
			$c->app->log->debug("copying video asset " . $upload->filename);
			my @parts = split /\./, $upload->filename;
			my $ext = pop @parts;
			my $relname = dirname($talk->relative_name);
			my $fn = join('.', $relname, $ext);
			my $coll;
			if($collname eq "input") {
				$coll = SReview::Files::Factory->create("input", $c->srconfig->get("inputglob"), $c->srconfig);
			} elsif($collname eq "pub") {
				$coll = SReview::Files::Factory->create("intermediate", $c->srconfig->get("pubdir"), $c->srconfig);
			} else {
				$coll = SReview::Files::Factory->create($collname, $c->srconfig->get("extra_collections")->{$collname});
			}
			$c->app->log->debug("Opened collection for $collname");
			my $file = $coll->add_file(relname => join("/", "injected", $fn));
			$c->dbh->prepare("DELETE FROM raw_files WHERE filename LIKE ? AND stream = 'injected' AND room = ?")->execute($coll->url . "/injected/" . $relname . ".%", $talk->roomid);
			my $st = $c->dbh->prepare("INSERT INTO raw_files(filename, room, starttime, stream, collection_name) VALUES(?,?,?,'injected', ?) ON CONFLICT DO NOTHING");
			$st->execute($file->relname, $talk->roomid, $talk->corrected_times->{start}, $collname);
			my $target = $file->filename;
			$c->app->log->debug("Copying file to $target");
			$upload->move_to($target);
			$c->app->log->debug("Checking video asset " . $upload->filename);
			my $input = Media::Convert::Asset->new(url => $file->filename);
			my $checks = $c->srconfig->get("inject_fatal_checks");
			foreach my $prop(keys %$checks) {
				my $attr = $input->meta->find_attribute_by_name($prop);
				my $val = $attr->get_value($input);
				if(!defined($val)) {
					$c->stash(short_error => "Invalid upload");
					$c->stash(error => "Could not find the attribute <tt>$prop</tt> of the uploaded file. Cannot process this file.");
					$c->render(variant => "error");
					return;
				} elsif(exists($checks->{$prop}{min}) && exists($checks->{$prop}{max})) {
					if(($val > $checks->{$prop}{max}) || ($val < $checks->{$prop}{min})) {
						$c->stash(short_error => "Invalid upload");
						$c->stash(error => "Value of property <tt>$prop</tt> out of bounds for the uploaded file. Cannot process this file.");
						$c->render(variant => "error");
						return;
					}
				} elsif(exists($checks->{$prop}{val})) {
					if($val ne $checks->{$prop}{val}) {
						$c->stash(short_error => "Invalid upload");
						$c->stash(error => "Value of property <tt>$prop</tt> does not string-equal expected value. Cannot process this file.");
						$c->render(variant => "error");
						return;
					}
				} elsif(exists($checks->{$prop}{talkattr_max})) {
					my $talkattr = $talk->meta->find_attribute_by_name($checks->{$prop}{talkattr_max});
					if($val >= $talkattr->get_value($talk)) {
						$c->stash(short_error => "Invalid upload");
						$c->stash(error => "Value of property <tt>$prop</tt> is too high for this talk. Cannot process this file.");
						$c->render(variant => "error");
						return;
					}
				} else {
					die "invalid configuration: $prop requires either minimum and maximum, or an exact value.";
				}
			}
			$c->app->log->debug("Checks complete, committing");
			$file->store_file;
			$talk->active_stream("injected");
			$talk->set_state("injecting");
			$talk->done_correcting;
		} elsif($upload->name eq "other_asset") {
			next unless defined($upload->filename) && length($upload->filename) > 0;
			$c->app->log->debug("copying other asset " . $upload->filename);
			my $coll = SReview::Files::Factory->create($collname, $c->srconfig->get("extra_collections")->{$collname}, $c->srconfig);
			my $file = $coll->add_file(relname => join("/", "assets", $talk->slug, $upload->filename));
			$upload->move_to($file->filename);
			$file->store_file;
		}
		$c->app->log->debug($upload->filename . " done");
	}
	$c->render;
}

1;
