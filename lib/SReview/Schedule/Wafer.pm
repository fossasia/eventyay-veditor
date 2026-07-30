package SReview::Schedule::Wafer::Talk;

use Moose;
use Mojo::Util 'slugify';
use DateTime::Format::ISO8601;

extends 'SReview::Schedule::Penta::Talk';

sub _load_upstreamid {
	return shift->schedref->attribute('guid');
}

sub _load_slug {
	return shift->xml_helper('slug');
}

sub _load_speakers {
	my $self = shift;

	return [] if (grep(/^persons$/, $self->schedref->children_names) == 0);
	return $self->SUPER::_load_speakers;
}

sub _load_filtered {
	my $rec = shift->schedref->child("recording");
	return 0 unless defined($rec);
	return 1 if $rec->child("optout")->value eq "true";
	return 0;
}

sub _load_starttime {
	return DateTime::Format::ISO8601->parse_datetime(shift->xml_helper('date'));
}

no Moose;

package SReview::Schedule::Wafer::Event;

use Moose;
use DateTime::TimeZone;

extends 'SReview::Schedule::Penta::Event';

sub _load_timezone {
	my $self = shift;
	my $timezone = DateTime::TimeZone->new(name => $self->schedref->child('time_zone_name'));
	return DateTime::TimeZone->new(name => $timezone->value) if defined($timezone);
	return $self->SUPER::_load_timezone;
}

no Moose;

package SReview::Schedule::Wafer;

use Moose;
use SReview::Schedule::Penta;

extends 'SReview::Schedule::Penta';

=head1 NAME

SReview::Schedule::Wafer - sreview-import schedule parser for the Pentabarf XML format as created by the Wafer conference management system.

=head1 DESCRIPTION

The Wafer conference management system has the ability to create an XML
version of its schedule that is compatible with the Pentabarf XML
format. However, it is mildly different in the way it creates it, most
significantly in the way it creates unique IDs. As such, importing such
a schedule with the L<SReview::Schedule::Penta> parser will fail to
create a stable schedule in SReview.

This parser uses the L<SReview::Schedule::Penta> parser with the minimal
required changes to make it work with the Wafer schedule parser.

=head1 OPTIONS

C<SReview::Schedule::Wafer> only supports one option:

=head2 url

The URL where the schedule can be found.

=head1 SEE ALSO

L<SReview::Schedule::Multi>, L<SReview::Schedule::Penta>

=cut

sub _load_talk_type {
	return 'SReview::Schedule::Wafer::Talk';
}

sub _load_event_type {
	return 'SReview::Schedule::Wafer::Event';
}

no Moose;

1;
