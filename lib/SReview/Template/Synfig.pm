package SReview::Template::Synfig;

use SReview::Template;
use Mojo::UserAgent;
use Mojo::Util qw/xml_escape/;
use File::Temp qw/tempdir/;

use Exporter 'import';
our @EXPORT_OK = qw/process_template/;

=head1 NAME

SReview::Template::Synfig - module to process a Synfig template into a PNG
file

=head1 SYNOPSIS

  use SReview::Template::Synfig qw/process_template/;
  use SReview::Talk;
  use SReview::Config::Common;

  my $talk = SReview::Talk->new(talkid => ...);
  my $config = SReview::Config::Common::setup();

  process_template($input_svg_template, $output_png_filename, $talk, $config);

  # now a PNG file is written to $output_png_filename

=head1 DESCRIPTION

C<SReview::Template::Synfig> uses L<SReview::Template> to process an input
file into a templated Synfig file, and then runs synfig over it to
convert the templated Synfig file to a PNG file at the given location.

The input file can either be a file on the local file system, or it can
be an HTTP or HTTPS URL (in which case the template at that location
will first be downloaded, transparently).

=head1 CONFIGURATION

This module checks the following configuration values:

=head2 workdir

The location for temporary files that the module needs.

=cut

sub process_template($$$$) {
	my $input = shift;
	my $output = shift;
	my $talk = shift;
	my $config = shift;

	my $tempdir = tempdir('svgXXXXXX', DIR => $config->get("workdir"), CLEANUP => 1);
	my $outputsif = "$tempdir/tmp.sif";
	my $content = "";
	my $template_engine = SReview::Template->new(talk => $talk);

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
	open my $fh, ">:encoding(UTF-8)", $outputsif;
	print "creating $output from $input\n";
	print $fh $template_engine->string($content);
	close $fh;
	system("synfig -o $output $outputsif");
}

1;
