package SReview::Credits;

use strict;
use warnings;

use feature "signatures";
no warnings "experimental::signatures";

use Exporter 'import';

use File::Copy qw/copy/;
use File::Temp qw/tempdir/;

use SReview::Template::SVG;
use SReview::Template::Synfig;

use Media::Convert::Asset::PNGGen;
use Media::Convert::Asset;
use Media::Convert::Pipe;
use Media::Convert::Asset::ProfileFactory;

our @EXPORT_OK = qw/process_template ensure_credit_png ensure_credit_preview/;

sub process_template($template, $output, $talk, $config) {

	my $format = $config->get("template_format");

	if($format eq "svg") {
		SReview::Template::SVG::process_template($template, $output, $talk, $config);
		return $output, [], [duration => 5];
	} elsif($format eq "synfig") {
		SReview::Template::Synfig::process_template($template, $output, $talk, $config);
		my @output = split/\./, $output;
		my $ext = pop @output;
		push @output, "%04d", $ext;
		$output = join(".", @output);
		my $dur = Media::Convert::Asset::PNGGen->new(url => $output);
		return $output, [loop => 0], [duration => undef, duration_frames => $dur->duration_frames];
	}
	die "Could not transform templates: template_format config value set to invalid value $format";
}

sub ensure_credit_preview($suffix, $talk, $config, $output_coll, $force) {

	my %valid_suffix = (
		pre => ["preroll_template"],
		post => ["postroll_template", "postroll"],
		sorry => ["apology_template"],
	);

	return undef unless exists($valid_suffix{$suffix});

	if($suffix eq 'sorry') {
		return undef unless defined($talk->apology) && length($talk->apology) > 0;
	}

	my $format = $config->get("template_format");
	if($format eq 'svg') {
		if(scalar(@{$valid_suffix{$suffix}}) > 1) {
			my $png = $config->get($valid_suffix{$suffix}[1]);
			if(defined $png && -f $png) {
				my $relname = $talk->relative_name . "/" . $suffix . ".png";
				if((defined($force) && $force ne 'false') || !($output_coll->has_file($relname))) {
					my $out_file = $output_coll->add_file(relname => $relname);
					copy($png, $out_file->filename) or die "could not copy $png to " . $out_file->filename . ": $!";
					$out_file->store_file;
				}
				return { filename => $png, content_type => 'image/png', is_video => 0 };
			}
		}

		my $template = $config->get($valid_suffix{$suffix}[0]);
		return undef unless defined $template;

		my $relname = $talk->relative_name . "/" . $suffix . ".png";
		if((defined($force) && $force ne 'false') || !($output_coll->has_file($relname))) {
			my $out_file = $output_coll->add_file(relname => $relname);
			process_template($template, $out_file->filename, $talk, $config);
			$out_file->store_file;
		}

		return { filename => $output_coll->get_file(relname => $relname)->filename, content_type => 'image/png', is_video => 0 };
	} elsif($format eq 'synfig') {
		my $template = $config->get($valid_suffix{$suffix}[0]);
		return undef unless defined $template;

		my $relname = $talk->relative_name . "/" . $suffix . ".webm";
		if((defined($force) && $force ne 'false') || !($output_coll->has_file($relname))) {
			my $workdir = $config->get('workdir');
			my $tmpdir = tempdir('creditsXXXXXX', DIR => $workdir, CLEANUP => 1);
			my $base_png = "$tmpdir/$suffix.png";
			my ($pattern, $inopts, $outopts) = process_template($template, $base_png, $talk, $config);

			my $main_rel = $talk->relative_name . "/main.mkv";
			my $main_file = $output_coll->get_file(relname => $main_rel);
			my $main_input = Media::Convert::Asset->new(url => $main_file->filename);
			my $profile;
			if(defined($config->get("input_profile"))) {
				$profile = Media::Convert::Asset::ProfileFactory->create($config->get("input_profile"), $main_input, $config->get('extra_profiles'));
			} else {
				$profile = $main_input;
			}

			my $out_file = $output_coll->add_file(relname => $relname);
			my $out_asset = Media::Convert::Asset->new(url => $out_file->filename, reference => $profile, video_codec => 'vp8', audio_codec => 'vorbis');
			Media::Convert::Pipe->new(inputs => [Media::Convert::Asset::PNGGen->new(url => $pattern, reference => $profile, @$inopts)], output => $out_asset, vcopy => 0, acopy => 0)->run();
			$out_file->store_file;
		}
		return { filename => $output_coll->get_file(relname => $relname)->filename, content_type => 'video/webm', is_video => 1 };
	}

	die "Could not transform templates: template_format config value set to invalid value $format";
}

sub ensure_credit_png($suffix, $talk, $config, $output_coll, $force) {
	my $res = ensure_credit_preview($suffix, $talk, $config, $output_coll, $force);
	return undef unless defined $res;
	return undef if $res->{is_video};
	return $res->{filename};
}

1;
