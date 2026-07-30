use strict;
use warnings;

package SReview::Config;

use Data::Dumper;
use Carp;
use Mojo::JSON qw/decode_json encode_json/;
use Text::Format;

=head1 NAME

SReview::Config - Self-reproducing and self-documenting configuration file system

=head1 SYNOPSIS

  use SReview::Config;

  my $config = SReview::Config->new('/etc/sreview/config.pm');
  $config->define('name', 'The name of this element', 'default');
  ...
  print "You configured " . $config->get('name') . " as the name\n";
  print "Full configuration: \n" . $config->dump;

=head1 DESCRIPTION

SReview::Config is a class to easily manage self-reproducing and
self-documenting configuration. You create an SReview::Config object,
populate it with possible configuration values, and then retrieve them.

=head1 METHODS

=head2 SReview::Config->new('path/to/filename');

Create a new SReview::Config object.

=cut

sub new {
	my $self = {defs => {}};
	my $class = shift;

	bless $self, $class;

	my $cfile = shift;

	if (! -f $cfile) {
		unless (grep /^SREVIEW_/, keys(%ENV)) {
			carp "Warning: could not find configuration file $cfile, falling back to defaults";
		}
	} else {
		package SReview::Config::_private;
		use Carp;
		my $rc = do($cfile);
		if($@) {
			croak "could not compile config file $cfile: $@";
		} elsif(!defined($rc)) {
			carp "could not read config file $cfile. Falling back to defaults.";
		} elsif(!$rc) {
			croak "could not process config file $cfile";
		}
	}
	return $self;
};

=head2 $config->define(name, doc, default)

Define a new configuration value. Not legal after C<get> has already
been called.

Name should be the name of the configuration value. Apart from the fact
that it should not have a sigil, it should be a valid name for a perl
scalar variable.

=cut

sub define {
	my $self = shift;
	my $name = shift;
	my $doc = shift;
	my $default = shift;
	if(exists($self->{fixed})) {
		croak "Tried to define a new value after a value has already been requested. This is not allowed!";
	}
	$self->{defs}{$name}{doc} = $doc;
	$self->{defs}{$name}{default} = $default;
	my $NAME = uc $name;
	if(exists($ENV{"SREVIEW_${NAME}"})) {
		$self->set($name => decode_json($ENV{"SREVIEW_${NAME}"}));
	}
};

=head2 $config->define_deprecated(oldname, newname, conversion_sub)

Define a name as a deprecated way of configuring things. When this value
is set, SReview::Config will issue a warning that this option is now
deprecated, and that the user should use some other option instead.

The conversion subroutine is an optional argument that should mangle the
value given to "oldname" into the value expected by "newname". If it
returns nonzero, then SReview::Config will croak. It will receive a
reference to the "config" object, the value that is trying to be set, and the
name of the new parameter.

The default conversion sub just sets the value of the newname
configuration without any conversion.

=cut

sub define_deprecated {
	my $self = shift;
	my $oldname = shift;
	my $newname = shift;
	my $convert = shift;

	if(exists($self->{fixed})) {
		croak "Tried to define a new value after a value has already been requested. This is not allowed!";
	}
	$self->{defs}{$oldname}{deprecated} = 1;
	$self->{defs}{$oldname}{instead} = $newname;
	if(defined($convert)) {
		$self->{defs}{$oldname}{convert} = $convert;
	} else {
		$self->{defs}{$oldname}{convert} = sub { my $self = shift; my $old = shift; $self->set($newname => $old); return 0; };
	}
	if(exists($SReview::Config::_private::{$oldname})) {
		carp "Found a value for \"$oldname\" when it was being defined as a deprecated name. Please convert this value to a value of $newname!\n";
		if ((&$self->{defs}{$oldname}{convert}($self, $SReview::Config::_private::{$oldname}, $newname)) != 0) {
			croak "Could not convert deprecated value to new name: $!";
		}
	}
	my $NAME = uc $oldname;
	if(exists($ENV{"SREVIEW_${NAME}"})) {
		$self->set($newname => decode_json($ENV{"SREVIEW_${NAME}"}));
	}
}

=head2 $config->define_computed('name')

Defines a default value for a particular configuration parameter through
a subroutine.

If the subroutine returns C<undef>, that value will be ignored (and the
normal logic for defining a default will be used).

Should be used on a parameter that has already been defined through
  $config->define

=cut

sub define_computed {
	my $self = shift;
	my $name = shift;
	my $sub = shift;

	$self->{defs}{$name}{sub} = $sub;
}

=head2 $config->get('name')

Return the value of the given configuration item. Also finalizes the
definitions of this configuration file; that is, once this method has
been called, the C<define> method above will croak.

The returned value will either be the default value configured at
C<define> time, the value configured in the configuration file, or the
value set (in JSON format) in the environment variable
C<SREVIEW_I<name> >, where I<name> is the upper-case version of the name
of the configuration item.

=cut

sub get {
	my $self = shift;
	my $name = shift;
	my $talk = shift;

	if(!exists($self->{defs}{$name})) {
		croak "e: definition for config file item $name does not exist!";
	}

	$self->{fixed} = 1;
	if(exists($self->{defs}{$name}{sub})) {
		my $rv = &{$self->{defs}{$name}{sub}}($self, $talk);
		if(defined($rv)) {
			return $rv;
		}
	}
	if(exists($SReview::Config::_private::{$name})) {
		return ${$SReview::Config::_private::{$name}};
	}
	if(defined($ENV{'SREVIEW_VERBOSE'}) && $ENV{'SREVIEW_VERBOSE'} gt 0) {
		print "No configuration value found for $name, using defaults\n";
	}
	return $self->{defs}{$name}{default};
};

=head2 $config->set('name', value);

Change the current value of the given configuration item.

Note, this does not change the defaults, only the configured value.

=cut

sub set {
	my $self = shift;
	my %vals = @_;

	foreach my $name(keys %vals) {
		if(! exists($self->{defs}{$name})) {
			croak "Configuration value $name is not defined yet";
		}
		{
			my $val = $vals{$name};
			if(exists($self->{defs}{$name}{deprecated})) {
				my $newname = $self->{defs}{$name}{instead};
				carp "A value for \"$name\" is being set, which is a deprecated name for $newname. Please update things for the new value\n";
				if ((&{$self->{defs}{$name}{convert}}($self, $vals{$name}, $self->{defs}{$name}{instead})) != 0) {
					croak "Could not convert deprecated value for $name to $newname format\n";
				}
				return;
			}
			$SReview::Config::_private::{$name} = \$val;
		}
	}
}

=head2 $config->describe('name');

Return the documentation string for the given name

=cut

sub describe {
	my $self = shift;
	my $conf = shift;

	return $self->{defs}{$conf}{doc};
}

=head2 $config->dump

Return a string describing the whole configuration.

Each configuration item will produce one of the following two
formats:

=over

=item *

For an item that only has a default set:

  # Documentation value given to define
  #$name = "default value";

=item *

For an item that has a different value configured (either through the
configuration file, or through C<set>):

  # Documentation value given to define
  $name = "current value";

=cut

sub dump {
	my $self = shift;
	my $formatter = Text::Format->new(firstIndent => 0);
	my $rv = "SReview configuration file";
	$rv .= "\n" . "=" x length($rv) . "\n";
	$rv .= $formatter->paragraphs("This configuration file contains all the configuration options known to SReview. To change any configuration setting, you may either modify this configuration file, or you can run 'sreview-config --set=key=value -a update'. The latter method will rewrite the whole configuration file, removing any custom comments. It is therefore recommended that you use one or the other, but not both. However, it will also write the default values for all known configuration items to this config file (in a commented-out fashion).", "Every configuration option is preceded by a comment explaining what it does, and the legal values it can accept.");
	$rv =~ s/^/# /gm;
	$rv .= "\n";
	$rv .= $formatter->paragraphs("# Allow utf-8 strings");
	$rv .= "use utf8;\n\n";
	$Data::Dumper::Indent = 1;
	$Data::Dumper::Sortkeys = 1;

	foreach my $conf(sort(keys %{$self->{defs}})) {
		my $comment = $conf . "\n" . "-" x length($conf) . "\n" . $formatter->format($self->{defs}{$conf}{doc});
		$comment =~ s/^/# /gm;
		$rv .= $comment;
		if(exists($SReview::Config::_private::{$conf}) && (!defined($self->{defs}{$conf}{default}) || ${$SReview::Config::_private::{$conf}} ne $self->{defs}{$conf}{default})) {
			$Data::Dumper::Pad = "";
			$rv .= Data::Dumper->Dump([${$SReview::Config::_private::{$conf}}], [$conf]) . "\n";
		} else {
			$Data::Dumper::Pad = "#";
			$rv .= Data::Dumper->Dump([$self->{defs}{$conf}{default}], [$conf]) . "\n";
		}
	}
	$rv .= "# Do not remove this, perl needs it\n1;\n";

	return $rv;
};

=back

=head2 $config->dump_item("item")

Print a JSON value for the given configuration item. Prints the default
item if this item hasn't been set a value.

=cut

sub dump_item {
	my ($self, $item) = @_;

	print encode_json($self->get($item));
}

=head2 $config->is_default("item")

Return a truthy value if the given configuration item is still at its
default value.

=cut

sub is_default {
	my ($self, $item) = @_;

	return (exists($SReview::Config::_private::{$item})) ? 0 : 1;
}

=head2 $config->keys

Returns a list (unsorted) of all the known configuration names.

=cut

sub keys {
	my $self = shift;
	return keys %{$self->{defs}};
}

=head1 BUGS

It is currently not possible to load more than one configuration file in
the same process space. This will be fixed at some point in the future.

=cut

1;
