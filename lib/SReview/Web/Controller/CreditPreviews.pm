package SReview::Web::Controller::CreditPreviews;

use Mojo::Base 'Mojolicious::Controller';

use SReview::Talk;
use SReview::Files::Factory;
use SReview::Credits qw/ensure_credit_preview/;

my %valid_suffix = (pre => 1, post => 1, sorry => 1);

sub serve_png {
	my $c = shift->openapi->valid_input or return;;
	my $slug = $c->param("slug");
	my $suffix = $c->stash("suffix");
	my $nonce = $c->param("nonce");
	my $talk;
	if(defined($slug)) {
		$talk = SReview::Talk->by_slug($slug);
	} elsif(defined($nonce)) {
		$talk = SReview::Talk->by_nonce($nonce);
	} else {
		$c->app->log->debug("no slug or nonce, can't generate a preview");
		return $c->reply->not_found;
	}
	if(!defined($talk)) {
		$c->app->log->debug("talk not found");
		return $c->reply->not_found;
	}
	my $input_coll = SReview::Files::Factory->create("intermediate", $c->srconfig->get("pubdir"));
	if(!exists($valid_suffix{$suffix})) {
		$c->app->log->debug("invalid suffix, ignored");
		return $c->reply->not_found;
	}
	my $force = $c->param("force");
	my $res = ensure_credit_preview($suffix, $talk, $c->srconfig, $input_coll, $force);
	if(!defined($res) || !defined($res->{filename}) || !(-f $res->{filename})) {
		$c->app->log->debug("credit preview not available");
		return $c->reply->not_found;
	}
	$c->app->log->debug("serving rendered file...");
	$c->res->headers->content_type($res->{content_type});
	return $c->reply->file($res->{filename});
}

1;
