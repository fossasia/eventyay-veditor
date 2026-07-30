package SReview::Files::Factory;

use SReview::Config::Common;

sub create {
	my $class = shift;
	my $target = shift;
	my $relname = shift;
	my $config = SReview::Config::Common::setup();

	my $methods = $config->get("accessmethods");
	my $method;
	if(!exists($methods->{$target})) {
		die "missing method for $target\n";
	}
	$method = $methods->{$target};
	eval "require SReview::Files::Collection::$method;";
	if($@) {
		die "$@: $!";
	}
	if($target eq "input") {
		return "SReview::Files::Collection::$method"->new(globpattern => $relname, collection_name => $target);
	} else {
		return "SReview::Files::Collection::$method"->new(baseurl => $relname, collection_name => $target);
	}
}

1;

__END__

=head1 NAME

SReview::Files::Factory

=head1 SYNOPSIS

  my $config = SReview::Config::Common::setup();
  my $collection = SReview::Files::Factory->create("input", $config->get("inputglob"), $config);
  my $contents = $collection->children;

  NAME:
  foreach my $name(@$contents) {
        next NAME if($name->is_collection);
        print $name->url . "\n";
  }

=head1 DESCRIPTION

This module is used internally by SReview to abstract access to files.

The C<Factory> class contains an implementation for direct (i.e.,
through the filesystem) access to files. Alternative implementations
exist for other access methods (through HTTP, S3, SSH, etc.) as separate
modules.

=head1 METHODS

=head2 create

Factory method to create an object for a specific collection.

Takes two positional arguments: the first is the name of the collection; the
second is the C<relname> of the collection.

If the name is C<input>, the C<relname> argument is passed as the
C<globpattern> property for the newly-created collection. In all other
cases, the C<relname> is passed as the C<baseurl>.

Returns a new L<SReview::Files::Collection::Base> object.

=head1 AUTHOR

Wouter Verhelst <w@uter.be>

=cut
