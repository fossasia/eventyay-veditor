# SReview

## Quick Start (Setup and Test from Scratch)

If you are setting up SReview for the first time or want to run a quick test, follow these steps:

1. **Start the environment:** Ensure Docker Desktop is running, then start all services in the background:
   ```bash
   docker compose up -d --build
   ```
2. **Access the Web Interface:** Open `http://localhost:3000` in your web browser. You will see a test event already created for you.
3. **Simulate a Camera Upload:** Drop a raw video file (e.g., an `.mp4` or `.mkv` file) into the `dev-incoming/testroom/2026-07-24/` folder. Name the file `08:30:00.mkv` to match the exact start time of the pre-configured test talk.
4. **Run the Detector:** Tell SReview to scan the incoming folder for the new file and match it to the schedule:
   ```bash
   docker compose exec web perl /usr/src/scripts/sreview-detect --day-finished --verbose
   ```
   Refresh your browser. The "My Test Video" talk will now be in the `waiting_for_files` or `cutting` state.
5. **Start the Background Dispatcher:** Run the background worker that handles video cutting, transcoding, and preview generation:
   ```bash
   docker compose exec web perl -I /usr/src/lib /usr/src/scripts/sreview-dispatch
   ```
   Watch the terminal as it processes the video. Once it finishes the `generating_previews` state, refresh your browser. The state will now be `preview`.
6. **Human Review:** In the web dashboard, click on the **"My Test Video"** hyperlink. You will be taken to the review player where you can adjust start/end times via sliders and select the preferred audio channel. Click "Approve" when done.
7. **Final Rendering:** The background dispatcher will wake up again, apply your edits, stitch the final credits, and output the polished video into the `dev-output/` folder!

---

This is SReview, a video review system. It takes input files, stores
their lengths in a database, combines those lengths and their starttime
with a schedule it has of an event to see which talks are fully
recorded, and creates a preview. After that, magic happens, and
eventually a fully transcoded quality video rolls out of the system.

Note that while SReview has been used [in
production](https://yoe.github.io/SReview/production), there is still
some missing functionality in some areas. Patches welcome! :-)

## States

SReview is fairly minimalistic; it tries to assume as little as possible
about video workflow. There are, however, state machines that you should be
aware of. First, there is the main state:

    waiting_for_files
    cutting
    generating_previews
    notification
    preview
    transcoding
    uploading
    done
    broken
    needs_work
    lost
    ignored

Next, there is the job state:

    waiting
    scheduled
    running
    done
    failed

Every talk is in one of the main states as well as in one of the job. The
following list explains what each of the main states means:

- `waiting_for_files`: no files (or not all of them) have been found as of yet.
  Talks should initially be in this state.
- `cutting`: the `cut_talk` script
- `generating_previews`: the `previews` script
- `notification`: a notification needs to be sent to the user responsible for
  reviewing the talk. This may be the speaker, or someone else.
- `preview`: the notification was sent. This talk is now ready for
  review by a human being (the webinterface is necessary for this step).
- `transcoding`: the `transcode` script is running, or scheduled to
  start.
- `uploading`: the files are being uploaded.
- `done`: the talk has been fully completed, all files should be
  published.
- `broken`: SReview will not automatically switch a talk to this state,
  but it can be used to mark talks that are lost forever and should not
  be considered anymore.
- `needs_work`: Refinement of `broken`. Can be used by an administrator
  to mark recordings that need larger amounts of work, but that may be
  fixed eventually.
- `lost`: Refinement of `broken`. Can be used by an administrator to
  confirm that a recording is broken and cannot be usefully released.
- `ignored`: Can be used by an administrator to mark recordings for
  talks that never happened, or that appeared on the schedule but don't
  include interesting content, or that appeared on the schedule but for
  which speakers requested that no recordings would be made available.

The job states, then, mean:

- `waiting`: For states that are handled by the system, it's waiting for the
  dispatch script to do something. For other states, it's waiting on
  something external to happen (e.g., a human needs to review in the
  `preview` state; the video must become visible in the `publishing`
  state, etc).
- `scheduled`: the script was picked up by the dispatch script, and has
  been put into the job scheduler's queue. If a slot is available, it
  will be started almost immediately; if not, it may need to wait until
  that's done.
- `running`: the script is now active and running.
- `done`: For states that are handled by the system, the script finished
  successfully. For other states, the external condition that needed to
  happen has happened (e.g., a human confirmed that the talk is OK to
  release in the `preview` state; the video has become visible in the
  `publishing` state).
- `failed`: the script did *not* finish successfully (note: when that
  happens, it doesn't always go into this state, currently).

## Components

SReview consists of two major components: a webinterface (written in
Perl with Mojolicious), and a backend which consists of another set of
perl scripts.

To run the webinterface in a test environment, run:

    export SREVIEW_WDIR=$(pwd)
    sreview-config --action=update

and review the `config.pm` file that this creates. Edit it, either by
way of an editor, or by using

    sreview-config --set=key=value --action=update

then run `sreview-web daemon`, and browse to the URL given. To run the
webinterface in production, see
[Mojo::Server::Hypnotoad](http://mojolicious.org/perldoc/Mojo/Server/Hypnotoad)
(or some of the other guides over there), or use the Debian packages
provided (which should make `sreview-web` start at system boot time).

To run the backend, it is recommended that you install gridengine first.
In theory, the backend *should* work without gridengine, but that is not
tested. Additionally, you will then need to run a dispatcher per CPU,
rather than having just one dispatcher in the whole network (which is
annoying).

Once gridengine has been installed, run `sreview-dispatch`.

If you have any issues with SReview, please file an issue (or better
yet, a pull request) on the github issue tracker.

# Development

To run SReview from git without installing, do the following:

- Install Perl, PostgreSQL, ffmpeg, inkscape, and bs1770gain
- Run `cpanm --quiet --installdeps --notest .` to install the Perl
  dependencies. Alternatively, install the packaged versions of the perl
  dependencies for your distribution.
- Add a PostgreSQL database and user:

        createuser -P sreview
        createdb -O sreview sreview

- Create an SReview config file:

        SREVIEW_WDIR=$(pwd) perl -I lib scripts/sreview-config -a update

  This creates a file "config.pm". Edit that file in your favourite
  editor; it should be self-documenting. Make sure to certainly edit the
  PostgreSQL connection string and the "secrets" variable.

- To add files to the database, store them in the inputdir (see config
  file), and run `SREVIEW_WDIR=$(pwd) perl -I lib
  scripts/sreview-detect`
- The webinterface expects to be run from the `web` directory, so:

        cd web
        SREVIEW_WDIR=$(pwd)/.. ./sreview-web daemon

Alternatively, you can use docker-compose:

- `docker compose up`

To edit the config file, either edit the line with `sreview-config` in `dockerfiles/web/local.Dockerfile`, or to edit from the host:

- Copy the config file from the container
`docker compose cp web:/etc/sreview/config.pm container-config.pm`

- Add a volume to the docker-compose file:

        services:
          web:
            volumes:
              - ./container-config.pm:/etc/sreview/config.pm


# Further reading

See the [documentation](docs/)
