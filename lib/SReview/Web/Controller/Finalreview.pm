package SReview::Web::Controller::Finalreview;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Collection 'c';

use SReview::Talk;
use SReview::Access qw/admin_for/;

sub view {
	my $c = shift;

	my $id = $c->stash("id");
	my $talk;
	$c->stash(adminspecial => 0);
	eval {
		if(defined($id)) {
			$talk = SReview::Talk->new(talkid => $id);
		} else {
			$talk = SReview::Talk->by_nonce($c->stash("nonce"));
		}
	};
	if($@) {
		$c->stash(error => $@);
		$c->render(variant => "error");
		return;
	}
	my $variant;
	my $nonce = $talk->nonce;
	if($talk->state eq "finalreview") {
		$variant = undef;
	} elsif(admin_for($c, $talk)) {
		$variant = undef;
		$c->stash(adminspecial => 1);
	} elsif($talk->state gt "finalreview" && $talk->state lt "done") {
		$variant = 'working';
	} elsif($talk->state ge 'remove' && $talk->state le 'removing') {
		$variant = 'working';
	} else {
		$variant = 'done';
	}
	$c->stash(talk => $talk);
	$c->stash(stylesheets => ['/review.css']);
	$c->render(variant => $variant);
}

sub update {
	my $c = shift;
	my $id = $c->stash("id");
	my $talk;

	$c->stash(stylesheets => ['/review.css']);
	eval {
		if(defined($id)) {
			$talk = SReview::Talk->new(talkid => $id);
		} else {
			$talk = SReview::Talk->by_nonce($c->stash("nonce"));
		}
	};
	if($@) {
		$c->stash(error => $@);
		$c->render(variant => "error");
		return;
	}
	$c->stash(talk => $talk);
	if(!admin_for($c, $talk) && $talk->state ne 'finalreview') {
		$c->stash(error => 'This talk is not currently available for final review. Please try again later!');
		$c->render(variant => 'error');
		return;
	}
	$talk->add_correction(serial => 0);
	if($c->param("serial") != $talk->corrections->{serial}) {
		$c->stash(error => 'This talk was updated (probably by someone else) since you last loaded it. Please reload the page, and try again.');
		$c->render(variant => 'error');
		return;
	}
	if(!defined($c->param("video_state"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <tt>video_state</tt>.');
		$c->render(variant => "error");
		return;
	}
	if(defined($c->param("comment_text")) && length($c->param("comment_text")) > 0) {
		$talk->comment($c->param("comment_text"));
	}
	if($c->param("video_state") eq "ok") {
		$talk->state_done("finalreview");
		$c->render(variant => "done");
		return;
	}
	$talk->set_state("remove");
	$c->render(variant => "unpublish");
}

1;
