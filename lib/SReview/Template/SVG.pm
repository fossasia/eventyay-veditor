package SReview::Template::SVG;

use SReview::Template;
use Mojo::UserAgent;
use Mojo::Util qw/xml_escape/;
use File::Temp qw/tempdir/;

use Exporter 'import';
our @EXPORT_OK = qw/process_template/;

=head1 NAME

SReview::Template::SVG - module to process an SVG template into a PNG
file

=head1 SYNOPSIS

  use SReview::Template::SVG qw/process_template/;
  use SReview::Talk;
  use SReview::Config::Common;

  my $talk = SReview::Talk->new(talkid => ...);
  my $config = SReview::Config::Common::setup();

  process_template($input_svg_template, $output_png_filename, $talk, $config);

  # now a PNG file is written to $output_png_filename

=head1 DESCRIPTION

C<SReview::Template::SVG> uses L<SReview::Template> to process an input
file into a templated SVG file, and then runs inkscape over it to
convert the templated SVG file to a PNG file at the given location.

The input file can either be a file on the local file system, or it can
be an HTTP or HTTPS URL (in which case the template at that location
will first be downloaded, transparently).

=head1 TEMPLATE TAGS

In addition to the L<Mojo::Template> syntax on C<$talk> that
L<SReview::Template> provides, C<SReview::Template::SVG> also passes the
these regexvars to L<SReview::Template> (for more information, see
SReview::Template):

=over

=item @SPEAKERS@

The value of C<$talk-E<gt>speakers>

=item @ROOM@

The value of C<$talk-E<gt>room>

=item @TITLE@

The value of C<$talkE<gt>title>

=item @SUBTITLE@

The value of C<$talkE<gt>subtitle>

=item @DATE@

The value of C<$talkE<gt>date>

=item @APOLOGY@

The value of C<$talkE<gt>apology>

=back

Note that all these values are XML-escaped first.

=head1 CONFIGURATION

This module checks the following configuration values:

=head2 command_tune

If the value C<inkscape> in this hash is set to "C<0.9>", then the C<inkscape>
command is invoked with command-line parameters for Inkscape version 0.9
or below. In all other cases, command-line parameters for Inkscape
version 1.0 or above are used instead.

=head2 workdir

The location for temporary files that the module needs.

=cut

sub process_template($$$$) {
	my $input = shift;
	my $output = shift;
	my $talk = shift;
	my $config = shift;

	my $tempdir = tempdir('svgXXXXXX', DIR => $config->get("workdir"), CLEANUP => 1);
	my $outputsvg = "$tempdir/tmp.svg";
	my $speakers = xml_escape($talk->speakers);
	my $room = xml_escape($talk->room);
	my $title = xml_escape($talk->title);
	my $subtitle = xml_escape($talk->subtitle);
	my $startdate = xml_escape($talk->date);
	my $apology = xml_escape($talk->apology);
	my $regexvars = {
		'@SPEAKERS@' => $speakers,
                '@ROOM@' => $room,
                '@TITLE@' => $title,
                '@SUBTITLE@' => $subtitle,
                '@DATE@' => $startdate,
                '@APOLOGY@' => $apology,
        };
	my $content = "";
	my $template_engine = SReview::Template->new(talk => $talk, regexvars => $regexvars);

	if($input =~ /^http(s)?:\/\//) {
		my $ua = Mojo::UserAgent->new->connect_timeout(60)->max_redirects(10);
		my $res = $ua->get($input)->result;
		if(!$res->is_success) {
			die "could not download: " . $res->message;
		}
		$content = $res->body;
	} else {
		open INPUT, '<:encoding(UTF-8)', $input;
		while(<INPUT>) {
			$content .= $_;
		}
		close INPUT;
	}
	open my $fh, ">:encoding(UTF-8)", $outputsvg;
	print "creating $output from $input\n";
	print $fh $template_engine->string($content);
	close $fh;
	my $inkscape_options = "-o $output";
	$command_tune = $config->get('command_tune');
	if(exists($command_tune->{inkscape}) && $command_tune->{inkscape} eq "0.9") {
		$inkscape_options = "--export-png=$output";
	}
	system("inkscape $inkscape_options $outputsvg");
}

1;
