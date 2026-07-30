# SReview internal APIs

SReview containers a number of internal APIs, which are useful to know
about if you want to administer the SReview system. Additionally, if you
want to contribute to SReview, it helps to be aware of them.

The APIs are documented in POD format, but it's useful to have a bit of
an overview; that's what this document attempts to provide.

## Files API

The `SReview::Files` API provides access to media files. Any component
of the system that wants to access a file *must* use this API. This
allows for abstracting away the way in which the files are accessed. As
of this writing, implementations exist to access and detect files
directly on the filesystem (locally or via NFS), via an Amazon
S3-compatible API, via plain HTTP, via HTTP with nginx JSON indexes, and
via SSH.

### Collections

The Files API places each file in a "collection". A collection is a
logical grouping of files that can be accessed in a uniform way. For
instance, the "input directory" (as configured through the `inputglob`
configuration parameter) defines one collection.

The `SReview::Files` implementation to access files is configured at the
collection level, through the `accessmethods` configuration parameter.
This parameter should be a hash where each key is the name of a
collection to configure the collection implementation for, and the value
is the name of the implementing collection class, with the
`SReview::Files::Collection::` prefix dropped.

If the `accessmethods` configuration item does not contain a key for the
relevant collection, then the collection cannot be created and SReview
will produce an error.

SReview requires at least three collections:

1. The `input` collection contains raw files as they are received from
   the camera. The location where files in this collection are found is
   configured by the `inputglob` configuration item. For backwards
   compatibility reasons, this collection looks for files by way of an
   input glob, rather than a root URL; it is the only collection which
   requires that, but this distinction may be removed at a future point.
2. The `intermediate` collection contains the files that are served to
   the public for the review webinterface. The location where files in
   this collection are found is configured by the `pubdir` configuration
   item. For the webinterface to work, it must be served on the URL
   configured by the `vid_prefix` configuration item (which may be
   host-relative if it is served on the same hostname as the SReview
   webinterface itself).
3. The `output` collection contains the finalized files that are
   produced by SReview. The location for this collection is configured
   by the `outputdir` configuration item.
   This is the location where all transcoded files (the output of
   SReview) are written to by `sreview-transcode`; the `sreview-upload`
   script, however, *reads* files from this collection. If the
   `outputdir` is somehow directly readable over the Internet, then the
   use of `sreview-upload` is not required and the `uploading` state can
   be skipped. However, this may not be desireable, as the `direct`
   implementation (for direct filesystem access) does not use temporary
   files and writes directly to this collection, which may therefore
   result in incomplete files appearing to users.

These three collections are not optional and therefore assumed to always
be present.

If the `inject` functionality is enabled, then an extra collection, the
name of which should be specified the `inject_collection` configuration
item, is required. When doing so, an entry for the collection should be
present in the `accessmethods` configuration item, and the
`extra_collections` configuration item (which should also be a hash)
should contain a key for the same collection name with as its value the
base URL of the collection.

In some cases, it may be desireable to copy the files from one
collection to another as a way to upload scripts from the
`sreview-upload` script. In that case, the `sreview-copy` script can be
used, with relevant values in the `accessmethods` and
`extra_collections` configuration items.

### Creating objects

Creating an object is done by way of the `SReview::Files::Factory::create`
method. See the POD documentation for `SReview::Files::Factory` for details.

## Configuration API

### Overview

All SReview configuration is done through two dedicated modules,
`SReview::Config` and `SReview::Config::Common`. The former provides the
API, whereas the latter provides the specific configuration variables
used by SReview.

SReview supports setting configuration in the following ways:

1. Via environment variables. When doing so, the name of the environment
   variable should be the name of the configuration variable in upper
   case, prefixed with `SREVIEW_`. For instance, the configuration item
   `input_profile` can be set through the environment variable
   `SREVIEW_INPUT_PROFILE`. Each environment variable must be encoded in
   JSON; this includes strings, which means they need to have embedded
   quotes.
2. Via a configuration file, which is found using the following
   algorithm:

    1. If an environment variable `SREVIEW_WDIR` exists, look for a file
       `config.pm` in the directory pointed to by that variable. If it
       exists, use that.
    2. If a file `config.pm` exists in the current working directory,
       use that.
    3. If a file `config.pm` exists in the directory `/etc/sreview`, use
       that.

If a value is set in an environment variable, it takes precedence over
any value in the configuration file. If a value is not set in an
environment variable, *and* no value exists in a configuration file, the
built-in defaults, if any, will be used.

If environment variables are set and a configuration file is found too,
then both take effect. However, only one configuration file will be
considered; you can't have multiple configuration files. That said, as
the configuration file is a perl script, you *can* include a different
configuration file using normal perl syntax.

### Configuration tool

A dedicated tool, `sreview-config`, exists to manage configuration
items. It will parse the configuration in exactly the same way that the
other tools do, and it will then allow you to do things with that parsed
configuration.

It can:

1. Rewrite the configuration file with the default comments and all
   configuration values that are set to non-default values explicitly
   set;
2. Dump the configuration file as it *would* be written by step 1. to
   standard output (**note**: redirecting this output to a file that is
   in the search path of the current configuration will result in
   `sreview-config` finding an empty file, which means it will set
   everything to defaults; do not do that);
3. Extract the value of one specific configuration item to standard
   output (in JSON format);
4. Allow you to override one specific value on the command line before
   doing any of the above. However, this option only works for string
   options, and does not use the JSON encoding; it is therefore not
   recommended. Instead, you should set environment variables to
   override single options if you need to do this.

For more details, see the L<sreview-config> manual page.
