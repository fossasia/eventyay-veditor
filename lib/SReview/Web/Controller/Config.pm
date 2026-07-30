package SReview::Web::Controller::Config;

use Mojo::Base 'Mojolicious::Controller';

sub get_config {
	my $c = shift->openapi->valid_input;

	my $eventid = $c->eventid;
	my $config;
	if(defined($eventid)) {
		$config = { event => $c->eventid };
	} else {
		$config = {};
	}

	return $c->render(openapi => $config);
}

my $legend = [
	{ name => "waiting_for_files", expl => 'Still waiting for content for these talks' },
	{ name => "cutting", expl => 'Talk is being cut' },
	{ name => "generating_previews", expl => 'Talk previews are being generated' },
	{ name => "notification", expl => 'Sending out notifications' },
	{ name => "preview", expl => 'Talk ready for review, waiting for reviewer' },
	{ name => "transcoding", expl => 'High-quality transcodes running' },
	{ name => "fixuping", expl => 'Fixups running' },
	{ name => "uploading", expl => 'Uploading results' },
	{ name => "publishing", expl => 'Waiting for upload to appear in download area' },
	{ name => "notify_final", expl => 'Sending out notifications for final review' },
	{ name => "finalreview", expl => 'Ready for final review, waiting for reviewer' },
	{ name => "announcing", expl => 'Announcing completion of publication' },
	{ name => "transcribing", expl => 'Transcription running' },
	{ name => "syncing", expl => 'Syncing Uploads' },
	{ name => "done", expl => 'Videos published, all done' },
	{ name => "injecting", expl => 'Injecting manually-edited video' },
	{ name => "remove", expl => 'Final review found problems, talk being removed' },
	{ name => "removing", expl => 'Waiting for removal to finalize' },
	{ name => "broken", expl => 'Review found problems, administrator required' },
	{ name => "needs_work", expl => 'Fixable problems exist, manual intervention required' },
	{ name => "lost", expl => 'Unfixable problems exist, talk lost' },
	{ name => "ignored", expl => 'Talk disappeared from the schedule' },
	{ name => "uninteresting", expl => 'Talk marked as not relevant' },
];

sub get_legend {
	my $c = shift->openapi->valid_input or return;

	return $c->render(openapi => $legend);
}

1;
