package SReview::Template;

use Moose;
use Mojo::Template;
use SReview::Config::Common;

=head1 NAME

SReview::Template - process a string or a file and apply changes to it

=head1 SYNOPSIS

  use SReview::Template;
  use SReview::Talk;

  my $talk = SReview::Talk->new(...);
  my $template = SReview::Template->new(talk => $talk, vars => { foo => "bar" }, regexvars => {"@FOO@" => "foo"});
  my $processed = $template->string("The @FOO@ is <%== $foo %>, and the talk is titled <%== $talk->title %>");
  # $processed now contains "The foo is bar, and the talk is titled ..."
  # (with the actual talk title there)
  $template->file("inputfile.txt", "outputfile.txt"

=head1 DESCRIPTION

C<SReview::Template> is a simple wrapper around L<Mojo::Template>. All
the variables that are passed in to the "vars" parameter are passed as
named variables to L<Mojo::Template>.

In addition, some bits of SReview previously did some simple sed-like
search-and-replace templating. For backwards compatibility, this module
also supports such search-and-replace templating (e.g.,
L<SReview::Template::SVG> has a few of those). These, however, are now
deprecated; the C<$talk> variable and L<Mojo::Template>-style templates
should be used instead.

=head1 ATTRIBUTES

C<SReview::Template> objects support the following attributes:

=head2 talk

An L<SReview::Talk> object for the talk that this template is for.
Required. Will be passed on to the template as the C<$talk> variable.

=cut

has 'talk' => (
	is => 'ro',
	isa => 'SReview::Talk',
	required => 1,
);

has '_mt' => (
	is => 'ro',
	isa => 'Mojo::Template',
	default => sub { my $mt = Mojo::Template->new(); $mt->vars(1); },
);

=head2 vars

Additional L<Mojo::Template> variables to be made available to the
template.

=cut

has 'vars' => (
	is => 'ro',
	isa => 'HashRef',
);

=head2 regexvars

Variables to be replaced by search-and-replace.

=cut

has 'regexvars' => (
	is => 'ro',
	isa => 'HashRef[Str]',
	predicate => '_has_regexes',
);

=head1 METHODS

=head2 file

A method to process an input file through the templating engine into an
output file.

Takes to arguments: the name of the input file, followed by the name of
the output file.

Is implemented in terms of the C<string> method.

=cut

sub file {
	my $self = shift;
	my $inputname = shift;
	my $outputname = shift;

	local $_;

	open my $input, '<:encoding(UTF-8)', $inputname;
	open my $output, '>:encoding(UTF-8)', $outputname;
	while(<$input>) {
		$_ = $self->string($_);
		print $output $_;
	}
	close $input;
	close $output;
}

=head2 string

A function to process a string, passed as the only argument. Returns the
result of the template function.

=cut

sub string {
	my $self = shift;
	my $string = shift;
	my $vars = $self->vars;
	$vars->{talk} = $self->talk;

	my $rendered = $self->_mt->render($string, $vars);
	if($self->_has_regexes) {
		my $revals = $self->regexvars;
		foreach my $key(keys %{$revals}) {
			$rendered =~ s/$key/$revals->{$key}/g;
		}
	}
	return $rendered;
}

no Moose;

1;
