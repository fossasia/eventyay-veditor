Installing SReview
==================

This will install SReview in a way that is useful for a small
conference. That is, you expect to have no more than a handful of talks.

* Install the packages
  [sreview-detect](https://packages.debian.org/unstable/sreview-detect),
  [sreview-master](https://packages.debian.org/unstable/sreview-master),
  [sreview-encoder](https://packages.debian.org/unstable/sreview-encoder),
  and
  [sreview-web](https://packages.debian.org/unstable/sreview-web) on
  a *single* machine.
* The installation will create an sreview user and database, and will
  start the `sreview-web` service on port 8080, listening only to
  localhost. The sreview-web package also ships with an apache
  configuration snippet that shows how to proxy it from the interwebs.
  This is enabled by default, but may require an SSL configuration.
* Run `sreview-config --action=dump`. This will show you the current
  configuration of SReview. If you want to change something, either edit
  `/etc/sreview/config.pm`, or use `sreview-config --set=variable=value
  --action=update`.
* Run `sreview-user -d --action=create -u <your email>`. This will
  create an administrator user in the SReview database.
* Browse to the SReview webinterface (either on http://localhost:8080/,
  or on the apache-redirected standard web port).
* Set the `schedule_format` configuration option to one of the supported
  formats. They're all under `lib/SReview/Schedule`; as of this writing,
  parsers exist for pentabarf XML (`penta`), the wafer variant of
  pentabarf XML (`wafer`), a YAML-based format (`yaml`), and the ICS
  format (`ics`) that has however not seen a lot of testing.
  Additionally, a `multi` parser exists that allows you to create shadow
  copies of each found talk (useful if you want to perform multiple
  unrelated actions for each talk, e.g., have an injected prerecording
  system as well as a transcode of the output after the fact) and a
  `filtered` parser which stacks with another one and which can be used
  to ignore certain talks based on properties of those talks.
* Set the `schedule_options` configuration option so that the relevant
  options of the parser are set. Most parsers just expect a `url`
  parameter with the URL of the schedule file.
* Make sure to run `sreview-import` to import the schedule. This should
  run from cron once every half hour, normally.
* Decide whether you want notifications:
    - If you set the `anonreviews` configuration option to a nonzero
      value, then the `/overview` URL in the webinterface will have
      links to individual review pages. Reviewers can then just click on
      links and do review. However, an out-of-band mechanism for
      coordination between reviewers will be required. Note that review
      for talks not in the `previews` state will not be possible.
    - If you do *not* set that option, but create review volunteer users
      through the webinterface, then these users can go to the
      `/volunteer/list` URL, where they will receive a number of talks. These
      talks will be locked to them; the reviewers will have to finish the
      review.
    - If you add email addresses to speakers and/or track managers in
      the SReview database, and set the `notify_actions` configuration
      value to an array including `email`, the `email_template` variable
      to a Mojo::Template template for the email, the `email_from`
      configuration value to the email sender address, and the `urlbase`
      configuration value to the base URL where SReview can be found,
      then speakers and/or track managers will receive an email
      notification when a talk reaches the `previews` state containing
      the review link.
    - If you set the `notify_actions` configuration value to an array
      including `command`, and `notify_commands` to an array of arrays,
      then the command(s) in `notify_commands` will be run when a talk
      reaches the `previews` state. This may be used to, e.g., cause an
      IRC bot to say something.
* Review the `inputglob` and `parse_re` configuration parameters of
  SReview. The first should contain a filename glob pattern that will
  find your raw assets; the second should parse any given filename into
  room, year, month, day, hour, minute, and second components.
* Provide an SVG file for opening credits, and point to it from the
  `preroll_template` configuration value. See the `SVG TRANSFORMATIONS`
  section in the sreview-transcode POD documentation for details on how
  to do that.
* Provide an SVG or PNG file for closing credits, and point to it from
  the `postroll_template` (for SVG) or `postroll` (for PNG)
  configuration option.
* Store raw asset files, and make sure `sreview-detect` runs (it should
  do so from cron once every half hour by default).

The above configuration should work, and will be sufficient for a small
conference. The downside, however, is that there will be only one
backend process running at all times. When a talk reaches the `cutting`
state, but no `sreview-dispatch` process is available immediately, it
may take a *long* time for a process to become available for use.

There are two ways to fix that:

Using multiple cores
--------------------

In the default configuration, it is safe to run `sreview-dispatch`
multiple times. Each instance will request one job, run it, and then
request the next job.

However, it does not allow prioritizing short-running jobs (like
`sreview-cut`, which should never take more than a few minutes) over
long-running ones (like `sreview-transcode`, which may easily take
several hours). The result may be that reviewers may have to wait
before the system produces another review, which is not ideal.

Using a distributed resource manager
------------------------------------

A DRM like gridengine, SLURM, PBS, or Torque allows one to submit a job
and have it be run elsewhere. In such a configuration, you would
configure SReview to submit jobs to the DRM system, and it would then be
up to the DRM system to decide where to run it; e.g., it could be
configured to run high-I/O jobs (like `sreview-cut`) on the file server
where the files are directly available, whereas high-CPU jobs (like
`sreview-transcode`) would run on nodes with many CPU cores and
reasonable network bandwidth but not the fileserver.

Due to the increased flexibility in managing jobs that way, the author
of SReview *strongly* recommends the use of a DRM system for most
installations, even if SReview only runs on one system. However, because
setting up a DRM system is a lot of work and can be fairly complicated,
this is not the default mode of operation.

Since the author is most familiar with `gridengine`, a short tutorial on
how to set up a gridengine-based system follows. Instructions for other
DRM systems are welcome.

- Make sure all hosts have a fixed IP address of some sort. This may be
  a VPN IP or something, but it must exist.
- Make sure all hosts' FQDN resolves to that fixed IP address, not to
  something like `127.0.0.1` or (like is common on Debian) `127.0.1.1`.
- Make sure that all hosts can resolve each other by name. This may be
  through DNS or it may be through adding entries to `/etc/hosts`.
- Pick one host as the master host. On this host, install the
  `gridengine-master`, `gridengine-exec`, and `gridengine-client`
  packages.
- Run `qconf -ap smp`. This will open your editor with the configuration
  values for the `smp` PE that you're creating. Set the `slots` value to
  a number not lower than the total number of CPU cores on *all* the
  hosts you will be adding to the network. It's fine to set it to
  something ridiculously high, like `9999`. Save and exit.
- Run `qconf -ahgrp @allhosts`. This will open your editor with other
  configuration values. On the `hostlist` line, add the hostname of your
  master host. Save and exit.
- Run `qconf -aq lowprio.q`. Make the following changes:
    - Set the `slots` value here to the number of CPU cores that *each
      host* will have. That is, if you have 8 cores on every machine in
      your network, set it to 8. If you have 4 cores, set it to 4. If
      you have a mix of machines, choose the value that is valid for the
      master host for now.
    - Set the `pe_list` value to `smp` (we didn't create the `make` and
      `mpi` values, because we don't need them).
    - Set the `hostlist` value to `@allhosts`.
  Save and exit.
- Run `qconf -aq hiprio.q`. Make the same changes as for the
  `lowprio.q`, above. In addition to that, set the `subordinate_list`
  value to `slots=X(lowprio.q:0:sr)`, where `X` is the value you entered
  for `slots`. Save and exit.

The above creates a gridengine environment with two queues, one called
`lowprio.q` and one called `hiprio.q`. The system is configured such
that gridengine will *never* allow more jobs to be running than you have
CPU cores. However, if all CPUs are busy and a job is submitted in the
`hiprio.q` queue, gridengine will send `SIGSTOP` to all processes
started by the shortest-running job in the `lowprio.q` queue, and then
allow the `hiprio.q` job to be started. Once the `hiprio.q` job
finishes, the `lowprio.q` job will receive a SIGCONT and be allowed to
continue.

To add more worker machines to the system, install `gridengine-exec` on
all other machines in the network. Then, perform the following tasks on
the master:

- Run `qconf -ae <hostname>` for each of the other hosts. This creates
  "exec hosts" in the gridengine configuration.
- Run `qconf -mhgrp @allhosts`, and add the hostnames of the exechosts
  to the `hostlist` line.
- If one or more of the newly added exec hosts have more or less CPU
  cores than what you configured, then set the number of available slots
  on a per-node basis, using the following format:

      slots default,[hostname=value],[hostname=value]

  that is, set the default value for the "slots" configuration parameter
  first; and then for each host that should have a different value, use
  the format `[hostname=X]` for that host. e.g., if most of your hosts
  have 8 cores, but host `newbox.example.com` has 16 and host
  `oldthing.example.com` has 4, you would use:

      slots 8,[newbox.example.com=16],[oldthing.example.com=4]

  If you have more hosts than it turns out you need and you want to shut
  one down, note that it *is* possible to set the slots value to a value
  lower than the number of jobs already running on a particular host; if
  you do that, gridengine will allow jobs to be finished but not start
  any new jobs until the number of running jobs goes below the new
  `slots` value.
- If you prefer that the master host does not run any jobs (e.g.,
  because it is your fileserver and you don't want it to be distracted
  transcoding things), set its number of slots for a given queue to 0.
- Now run `qsub -q lowprio.q sleep 100`, and then run `qstat -q
  lowprio.q` a few times. You should see your job listed as `pending`
  first, and then after a few seconds it should be queued on a host.
  Once the job has run for 100 seconds, it should be removed from the
  system (you can remove it forcibly before its time is up by way of
  `qdel <jobid>`, where jobid is the number of the job that `qstat` will
  show you and which `qsub` returned in its output).
- If that worked, make sure that all exechosts have access to the files
  they need (e.g., through NFS or Samba), that they have
  the `sreview-encoder` package installed, and that their
  `/etc/sreview/config.pm` synchronized.
- Now, modify the `state_actions` so that rather than directly running
  your `sreview-*` commands, they are submitted into the `gridengine`
  system. e.g., the following would work:

          $state_actions = {
              'cutting' => 'qsub -cwd -pe smp 1 -b y -V -q hiprio.q -e <%== $output_dir %> -o <%== $output_dir %> -N cut_<%== $talkid %> sreview-cut <%== $talkid %>',
              'generating_previews' => 'qsub -cwd -pe smp 1 -b y -V -q hiprio.q -e <%== $output_dir %> -o <%== $output_dir %> -N preview_<%== $talkid %> sreview-previews <%== $talkid %>',
              'notification' => 'qsub -cwd -pe smp 1 -b y -V -q hiprio.q -e <%== $output_dir %> -o <%== $output_dir %> -N notify_<%== $talkid %> sreview-notify <%== $talkid %>',
              'transcoding' => 'qsub -cwd -pe smp 1 -b y -V -q lowprio.q -e <%== $output_dir %> -o <%== $output_dir %> -N transcode_<%== $talkid %> sreview-transcode <%== $talkid %>',
              'uploading' => 'qsub -cwd -pe smp 1 -b y -V -q lowprio.q -e <%== $output_dir %> -o <%== $output_dir %> -N upload_<%== $talkid %> sreview-upload <%== $talkid %>',
          };

Help!
=====

If you need more help, contact wouter:

- IRC: wouter on OFTC or Freenode
- email: wouter on the debian.org domain

