package SReview;

use strict;
use warnings;

our $VERSION;

$VERSION = "0.12.0";

=head1 NAME

SReview - a video review and transcoding system

=head1 DESCRIPTION

SReview is a system to review and transcode conference videos. You feed
it a bunch of timestamped videos and a schedule, and it creates initial
cuts based on that schedule. Next, you review (or ask reviewers) to
decide on the actual start- and end times of the talks, through a
webinterface. Once those start- and endtimes have been decided upon,
SReview prepends opening and closing credits, transcodes the videos to
archive quality, and publishes them.

For more information, see L<https://yoe.github.io/sreview>

=cut
