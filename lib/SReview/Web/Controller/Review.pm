package SReview::Web::Controller::Review;

use Mojo::Base 'Mojolicious::Controller';
use Mojo::Collection 'c';

use feature "switch";

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
                        $talk = SReview::Talk->by_nonce($c->stash('nonce'));
                }
        };
        if($@) {
                $c->stash(error => $@);
                $c->render(variant => 'error');
                return;
        }
        my $nonce = $talk->nonce;
	my $variant;
	if ($talk->state eq 'preview' || $talk->state eq 'broken') {
		$variant = undef;
	} elsif(admin_for($c, $talk)) {
		$variant = undef;
		$c->stash(adminspecial => 1);
	} elsif($talk->state < 'preview') {
		$variant = 'preparing';
	} elsif($talk->state < 'done') {
		$variant = 'transcode';
	} elsif($talk->state == 'injecting') {
		$variant = 'injecting';
	} else {
		$variant = 'done';
	}

	my $vid_prefix = $c->srconfig->get('vid_prefix');
	$vid_prefix = '' unless defined($vid_prefix);
	$c->stash(vid_prefix => $vid_prefix);
	$c->stash(template_format => ($c->srconfig->get('template_format') // 'svg'));

	$c->stash(talk => $talk);
	$c->stash(stylesheets => ['/review.css']);
	my $template = $c->srconfig->get("review_template");
	if(!defined($template)) {
		$template = ($talk->get_flag("is_injected") ? "confirm" : "full");
	}
	$c->render(template => "review/$template", variant => $variant);
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
			$c->stash(talk => SReview::Talk->new(talkid => 0, eventname => $c->srconfig->get("event"), title => "Not found"));
			$c->res->code(404);
                        $c->stash(error => $@);
                        return $c->render(variant => 'error');
                }
	}
        $c->stash(talk => $talk);
        if(!admin_for($c, $talk) && $talk->state ne 'preview' && $talk->state ne 'broken') {
                $c->stash(error => 'This talk is not currently available for review. Please try again later!');
                $c->render(variant => 'error');
		$c->res->code(403);
                return;
        }
        my $old_audio_channel = $talk->corrections->{audio_channel};
        $talk->add_correction(serial => 0);
        if($c->param('serial') != $talk->corrections->{serial}) {
                $c->stash(error => 'This talk was updated (probably by someone else) since you last loaded it. Please reload the page, and try again.');
		$c->res->code(409);
                $c->render(variant => 'error');
                return;
        }
        if(defined($c->param("comment_text")) && length($c->param("comment_text")) > 0) {
                $talk->comment($c->param("comment_text"));
        }

        if(defined($c->param("complete_reset")) && $c->param("complete_reset") eq "1") {
                $talk->reset_corrections();
                $talk->set_state("cutting");
                $c->render(variant => 'reset');
                return;
        }
	if(!defined($c->param("video_state"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <t>video_state</t>.');
		$c->res->code(400);
		$c->render(variant => "error");
		return;
	}
        if($c->param("video_state") eq "ok") {
		if($talk->corrections->{serial} == 0)  {
			$c->stash(error => 'No corrections have been applied to this talk yet. Unless (at least) start and end times are applied through this webinterface, the likelihood that the video starts and ends at the correct time is very low. Please go back and set the correct start and end times; if by extreme coincidence this video does start and end at the correct time, then please select the "there are problems" option in the previous screen, and submit the form without any changes.');
			$c->render(variant => "error");
			$c->res->code(400);
			return;
		}
                $talk->add_correction(serial => -1);
                $talk->done_correcting;
                $talk->state_done("preview");
                $c->render(variant => 'done');
                return;
        }
        my $corrections = {};
	if(!defined($c->param("audio_channel"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <t>audio_channel</t>.');
		$c->res->code(400);
		$c->render(variant => 'error');
		return;
	}
        if($c->param("audio_channel") ne "3") {
                if($c->param("audio_channel") ne $old_audio_channel) {
                        $talk->set_correction("audio_channel", $c->param("audio_channel"));
                        $corrections->{audio_channel} = $c->param("audio_channel");
                }
        } else {
                if($c->param("no_audio_options") eq "no_publish") {
                        $talk->set_state("broken");
                        $talk->comment("The audio is broken; the talk should not be released.");
                        $talk->done_correcting;
                        $c->render(variant => 'other');
                        return;
                }
        }
	if(!defined($c->param("start_time"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <t>start_time</t>.');
		$c->render(variant => 'error');
		return;
	}
        if($c->param("start_time") ne "start_time_ok") {
                $talk->add_correction("offset_start", $c->param("start_time_corrval"));
                $corrections->{start} = $c->param("start_time_corrval");
        }
	if(!defined($c->param("end_time"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <t>end_time</t>.');
		$c->render(variant => 'error');
		return;
	}
        if($c->param("end_time") ne "end_time_ok") {
                $talk->add_correction("offset_end", $c->param("end_time_corrval"));
                $corrections->{end} = $c->param("end_time_corrval");
        }
	if(!defined($c->param("av_sync"))) {
		$c->stash(error => 'Invalid submission data; missing parameter <t>av_sync</t>.');
		$c->render(variant => 'error');
		return;
	}
        if($c->param("av_sync") eq "av_not_ok_audio") {
                $talk->add_correction("offset_audio", $c->param("av_seconds"));
                $corrections->{audio_offset} = $c->param("av_seconds");
        } elsif($c->param("av_sync") eq "av_not_ok_video") {
                $talk->add_correction("offset_audio", "-" . $c->param("av_seconds"));
                $corrections->{audio_offset} = "-" . $c->param("av_seconds");
        }
        if(defined($c->param("broken")) && $c->param("broken") eq "yes") {
                $talk->set_state("broken");
                $c->stash(other_msg => $c->param("comment_text"));
                $talk->done_correcting;
                $c->render(variant => "other");
                return;
        }
        $talk->done_correcting;
        $talk->set_state("waiting_for_files");
        $talk->state_done("waiting_for_files");
        $c->stash(corrections => $corrections);
        $c->render(variant => 'newreview');
}

sub data {
        my $c = shift;
        my $talk = SReview::Talk->by_nonce($c->stash('nonce'));

        my $data = $talk->corrected_times;
	$c->app->log->debug($talk->video_fragments);
        $data->{filename} = $talk->relative_name . "/main" . $c->srconfig->get("preview_exten");
        $data->{room} = $talk->room;

        $c->render(json => $data);
}

1;
