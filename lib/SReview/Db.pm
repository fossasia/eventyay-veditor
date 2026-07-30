package SReview::Db;

use strict;
use warnings;

use Mojo::Pg;
use Mojo::Pg::Migrations;
use SReview::Config;

my $code;
my $init;

my $db;

sub selfdestruct {
	my %where = @_;
	for my $key('code', 'init') {
		if(!exists($where{$key})) {
			$where{$key} = 0;
		}
	}
	$code->migrate($where{code});
	$init->migrate($where{init});
}

sub init {
	my $config = shift;
	$db = Mojo::Pg->new->dsn($config->get('dbistring'));

	$code = Mojo::Pg::Migrations->new(pg => $db);
	$code->name('code');
	$code->from_data();
	$init = Mojo::Pg::Migrations->new(pg => $db);
	$init->name('init');
	$init->from_data();
	$code->migrate(0);
	$init->migrate() or return 0;
	$code->migrate() or return 0;
	if(defined($config->get("adminuser")) && defined($config->get("adminpw"))) {
		$db->db->dbh->prepare("INSERT INTO users(email, password, isadmin) VALUES(?, crypt(?, gen_salt('bf', 8)), true) ON CONFLICT ON CONSTRAINT users_email_unique DO NOTHING")->execute($config->get("adminuser"), $config->get("adminpw"));
	}

	return 1;
}

1;
__DATA__
@@ init
-- 1 up
CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;
-- 1 down
DROP EXTENSION IF EXISTS plpgsql;
DROP EXTENSION IF EXISTS pgcrypto;
-- 2 up
CREATE TYPE talkstate AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'needs_work',
    'lost'
);
CREATE TYPE jobstate AS ENUM (
    'waiting',
    'scheduled',
    'running',
    'done',
    'failed'
);
-- 2 down
DROP TYPE talkstate;
DROP TYPE jobstate;
-- 3 up
CREATE TABLE events (
    id SERIAL PRIMARY KEY,
    name character varying NOT NULL,
    time_offset integer DEFAULT 0 NOT NULL
);
CREATE TABLE rooms (
    id SERIAL PRIMARY KEY,
    name character varying,
    altname character varying
);
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    email character varying,
    password text,
    isadmin boolean DEFAULT false,
    room integer REFERENCES rooms(id),
    name character varying,
    isvolunteer boolean DEFAULT false
);
CREATE TABLE raw_files (
    id SERIAL PRIMARY KEY,
    filename character varying NOT NULL,
    room integer NOT NULL REFERENCES rooms(id),
    starttime timestamp with time zone,
    endtime timestamp with time zone
);
CREATE TABLE tracks (
    id SERIAL PRIMARY KEY,
    name character varying,
    email character varying,
    upstreamid character varying
);
CREATE TABLE talks (
    id SERIAL PRIMARY KEY,
    room integer NOT NULL REFERENCES rooms(id),
    slug character varying NOT NULL,
    nonce character varying DEFAULT encode(gen_random_bytes(32), 'hex'::text) NOT NULL UNIQUE,
    starttime timestamp with time zone NOT NULL,
    endtime timestamp with time zone NOT NULL,
    title character varying NOT NULL,
    event integer NOT NULL REFERENCES events(id),
    state talkstate DEFAULT 'waiting_for_files'::talkstate NOT NULL,
    progress jobstate DEFAULT 'waiting'::jobstate NOT NULL,
    comments text,
    upstreamid character varying NOT NULL,
    subtitle character varying,
    prelen interval,
    postlen interval,
    track integer REFERENCES tracks(id),
    reviewer integer REFERENCES users(id),
    perc integer,
    apologynote text,
    UNIQUE(event, slug)
);
CREATE TABLE speakers (
    id SERIAL PRIMARY KEY,
    email character varying,
    name character varying NOT NULL
);
CREATE TABLE speakers_talks (
    speaker integer REFERENCES speakers(id),
    talk integer REFERENCES talks(id),
    PRIMARY KEY (speaker, talk)
);
CREATE TABLE properties (
    id SERIAL PRIMARY KEY,
    name character varying,
    description character varying,
    helptext character varying
);
CREATE TABLE corrections (
    talk integer NOT NULL REFERENCES talks(id),
    property integer NOT NULL REFERENCES properties(id),
    property_value character varying,
    PRIMARY KEY(talk, property)
);
CREATE TABLE speakers_events (
    speaker integer NOT NULL REFERENCES speakers(id),
    event integer NOT NULL REFERENCES events(id),
    upstreamid character varying
);
-- 3 down
DROP TABLE speakers_events; 
DROP TABLE corrections;
DROP TABLE properties;
DROP TABLE speakers_talks;
DROP TABLE speakers;
DROP TABLE talks;
DROP TABLE tracks;
DROP TABLE raw_files;
DROP TABLE users;
DROP TABLE rooms;
DROP TABLE events;
-- 4 up
CREATE VIEW raw_talks AS
 SELECT talks.id AS talkid,
    talks.slug,
    raw_files.id AS rawid,
    raw_files.filename AS raw_filename,
    talks.starttime AS talk_start,
    talks.endtime AS talk_end,
    raw_files.starttime AS raw_start,
    raw_files.endtime AS raw_end,
    (talks.endtime - talks.starttime) AS talks_length,
    (raw_files.endtime - raw_files.starttime) AS raw_length,
    (LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime)) AS raw_length_corrected,
    sum((LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime))) OVER (PARTITION BY talks.id) AS raw_total,
        CASE
            WHEN (raw_files.starttime < talks.starttime) THEN (talks.starttime - raw_files.starttime)
            ELSE '00:00:00'::interval
        END AS fragment_start
   FROM talks,
    raw_files
  WHERE (((((talks.starttime >= raw_files.starttime) AND (talks.starttime <= raw_files.endtime)) OR ((talks.endtime >= raw_files.starttime) AND (talks.endtime <= raw_files.endtime))) OR ((talks.starttime <= raw_files.starttime) AND (talks.endtime >= raw_files.endtime))) AND (talks.room = raw_files.room));
CREATE VIEW last_room_files AS
 SELECT raw_files.filename,
    raw_files.starttime,
    raw_files.endtime,
    (date_part('epoch'::text, raw_files.endtime) - date_part('epoch'::text, raw_files.starttime)) AS length,
    rooms.name AS room
   FROM (raw_files
     JOIN rooms ON ((raw_files.room = rooms.id)))
  WHERE ((raw_files.room, raw_files.starttime) IN ( SELECT raw_files_1.room,
            max(raw_files_1.starttime) AS max
           FROM raw_files raw_files_1
          GROUP BY raw_files_1.room));
CREATE FUNCTION speakerlist(integer) RETURNS character varying
    LANGUAGE plpgsql STABLE
    AS $_$
 DECLARE
   crsr CURSOR FOR SELECT speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
   row RECORD;
   curname speakers.name%TYPE;
   prevname varchar;
   retval varchar;
 BEGIN
   retval=NULL;
   prevname=NULL;
   curname=NULL;
   FOR row IN crsr LOOP
     prevname = curname;
     curname = row.name;
     IF prevname IS NOT NULL THEN
       retval = concat_ws(', ', retval, prevname);
     END IF;
   END LOOP;
   retval = concat_ws(' and ', retval, curname);
   RETURN retval;
 END;
$_$;
CREATE VIEW mailers AS
 SELECT speakers.email,
    talks.nonce,
    talks.title
   FROM ((speakers_talks
     JOIN speakers ON ((speakers_talks.speaker = speakers.id)))
     JOIN talks ON ((speakers_talks.talk = talks.id)))
  WHERE (speakers.email IS NOT NULL);
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
CREATE FUNCTION adjusted_raw_talks(integer, interval, interval) RETURNS SETOF raw_talks
    LANGUAGE plpgsql
    AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start,
           talks.endtime + start_off + end_off AS talk_end,
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off)) OVER (range unbounded preceding),
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off THEN talks.starttime + start_off - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval THEN (talks.starttime + start_off - '00:20:00'::interval) - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - '00:20:00'::interval) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off THEN talks.endtime + start_off + end_off - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
CREATE FUNCTION corrections_redirect() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  corrs RECORD;
BEGIN
  FOR corrs IN SELECT * FROM corrections WHERE talk = NEW.talk AND property = NEW.property LOOP
    UPDATE corrections SET property_value = NEW.property_value WHERE talk = NEW.talk AND property = NEW.property;
    RETURN NULL;
  END LOOP;
  RETURN NEW;
END $$;
CREATE FUNCTION speakeremail(integer) RETURNS character varying
    LANGUAGE plpgsql
    AS $_$
DECLARE
  crsr CURSOR FOR SELECT speakers.email, speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
  row RECORD;
  retval VARCHAR;
BEGIN
  retval = NULL;
  FOR row IN crsr LOOP
    retval = concat_ws(', ', retval, row.name || ' <' || row.email || '>');
  END LOOP;
  RETURN retval;
END; $_$;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
CREATE TRIGGER corr_redirect_conflict BEFORE INSERT ON corrections FOR EACH ROW EXECUTE PROCEDURE corrections_redirect();
-- 4 down
DROP TRIGGER corr_redirect_conflict ON corrections;
DROP VIEW talk_list;
DROP VIEW mailers;
DROP VIEW last_room_files;
DROP FUNCTION state_next(talkstate);
DROP FUNCTION corrections_redirect();
DROP FUNCTION adjusted_raw_talks(integer, interval, interval);
DROP FUNCTION speakeremail(integer);
DROP FUNCTION speakerlist(integer);
DROP VIEW raw_talks;
-- 5 up
INSERT INTO properties(name, description, helptext) VALUES('length_adj', 'Length adjustment', 'Set a relative adjustment value for the talk here, specified in seconds. To shorten the talk length, enter a negative value; to increase the talk length, enter a positive value');
INSERT INTO properties(name, description, helptext) VALUES('offset_audio', 'Audio offset', 'Use for fixing A/V sync issues. Positive delays audio, negative delays video. Seconds; may be fractional.');
INSERT INTO properties(name, description, helptext) VALUES('audio_channel', 'Audio channel', 'Use 0 for the main channel, 1 for the alternate channel, or 2 for both channels mixed together');
INSERT INTO properties(name, description, helptext) VALUES('offset_start', 'Time offset', 'Use to adjust the time position of this talk. Negative values move the start to earlier in time, positive to later. Note that both start and end position are updated; if the end should not be updated, make sure to also set the "Length adjustment" value. Seconds; may be fractional.');
-- 5 down
DELETE FROM corrections WHERE property IN (SELECT id FROM properties WHERE name IN ('length_adj', 'offset_audio', 'audio_channel', 'offset_start'));
DELETE FROM properties WHERE name IN ('length_adj', 'offset_audio', 'audio_channel', 'offset_start');
-- 6 up
ALTER TABLE speakers ADD upstreamid VARCHAR;
-- 6 down
ALTER TABLE speakers DROP upstreamid;
-- 7 up
ALTER TABLE talks ADD description TEXT;
-- 7 down
ALTER TABLE talks DROP description;
-- 8 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'ignored',
    'needs_work',
    'lost'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 8 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'needs_work',
    'lost'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
UPDATE talks SET state='broken' WHERE state='ignored';
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 9 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 9 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'ignored',
    'needs_work',
    'lost'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 10 up
ALTER TABLE rooms ADD outputname VARCHAR;
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
-- 10 down
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
ALTER TABLE rooms DROP outputname;
-- 11 up
ALTER TABLE talks
  ADD CONSTRAINT check_positive_length
  CHECK (starttime < endtime);
ALTER TABLE events ADD inputdir VARCHAR, ADD outputdir VARCHAR;
-- 11 down
ALTER TABLE talks
  DROP CONSTRAINT check_positive_length;
ALTER TABLE events DROP inputdir, DROP outputdir;
-- 12 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'announcing',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 12 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
DROP VIEW talk_list;
UPDATE talks SET state='done' WHERE state='announcing';
ALTER TABLE talks ALTER state TYPE talkstate_new USING (state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM (((rooms
     LEFT JOIN talks ON ((rooms.id = talks.room)))
     LEFT JOIN events ON ((talks.event = events.id)))
     LEFT JOIN tracks ON ((talks.track = tracks.id)));
DROP FUNCTION state_next(talkstate);
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 13 up
DROP TRIGGER corr_redirect_conflict ON corrections;
DROP FUNCTION adjusted_raw_talks(integer, interval, interval);
DROP FUNCTION corrections_redirect();
DROP VIEW talk_list;
DROP FUNCTION speakerlist(integer);
DROP FUNCTION speakeremail(integer);
DROP FUNCTION state_next(talkstate);
DROP VIEW last_room_files;
DROP VIEW mailers;
DROP VIEW raw_talks;
-- 13 down
CREATE VIEW last_room_files AS
 SELECT raw_files.filename,
    raw_files.starttime,
    raw_files.endtime,
    date_part('epoch'::text, raw_files.endtime) - date_part('epoch'::text, raw_files.starttime) AS length,
    rooms.name AS room
   FROM raw_files
     JOIN rooms ON raw_files.room = rooms.id
  WHERE ((raw_files.room, raw_files.starttime) IN ( SELECT raw_files_1.room,
            max(raw_files_1.starttime) AS max
           FROM raw_files raw_files_1
          GROUP BY raw_files_1.room));
CREATE VIEW mailers AS
 SELECT speakers.email,
    talks.nonce,
    talks.title
   FROM speakers_talks
     JOIN speakers ON speakers_talks.speaker = speakers.id
     JOIN talks ON speakers_talks.talk = talks.id
  WHERE speakers.email IS NOT NULL;
CREATE VIEW raw_talks AS
 SELECT talks.id AS talkid,
    talks.slug,
    raw_files.id AS rawid,
    raw_files.filename AS raw_filename,
    talks.starttime AS talk_start,
    talks.endtime AS talk_end,
    raw_files.starttime AS raw_start,
    raw_files.endtime AS raw_end,
    talks.endtime - talks.starttime AS talks_length,
    raw_files.endtime - raw_files.starttime AS raw_length,
    LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime) AS raw_length_corrected,
    sum(LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime)) OVER (PARTITION BY talks.id) AS raw_total,
        CASE
            WHEN raw_files.starttime < talks.starttime THEN talks.starttime - raw_files.starttime
            ELSE '00:00:00'::interval
        END AS fragment_start
   FROM talks,
    raw_files
  WHERE (talks.starttime >= raw_files.starttime AND talks.starttime <= raw_files.endtime OR talks.endtime >= raw_files.starttime AND talks.endtime <= raw_files.endtime OR talks.starttime <= raw_files.starttime AND talks.endtime >= raw_files.endtime) AND talks.room = raw_files.room;
CREATE FUNCTION speakerlist(integer) RETURNS varchar
    LANGUAGE plpgsql STABLE
    AS $_$
 DECLARE
   crsr CURSOR FOR SELECT speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
   row RECORD;
   curname speakers.name%TYPE;
   prevname varchar;
   retval varchar;
 BEGIN
   retval=NULL;
   prevname=NULL;
   curname=NULL;
   FOR row IN crsr LOOP
     prevname = curname;
     curname = row.name;
     IF prevname IS NOT NULL THEN
       retval = concat_ws(', ', retval, prevname);
     END IF;
   END LOOP;
   retval = concat_ws(' and ', retval, curname);
   RETURN retval;
 END;
$_$;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
CREATE FUNCTION adjusted_raw_talks(integer, interval, interval) RETURNS SETOF raw_talks LANGUAGE plpgsql AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start,
           talks.endtime + start_off + end_off AS talk_end,
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off)) OVER (range unbounded preceding),
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off THEN talks.starttime + start_off - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval THEN (talks.starttime + start_off - '00:20:00'::interval) - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - '00:20:00'::interval) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off THEN talks.endtime + start_off + end_off - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
CREATE FUNCTION corrections_redirect() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  corrs RECORD;
BEGIN
  FOR corrs IN SELECT * FROM corrections WHERE talk = NEW.talk AND property = NEW.property LOOP
    UPDATE corrections SET property_value = NEW.property_value WHERE talk = NEW.talk AND property = NEW.property;
    RETURN NULL;
  END LOOP;
  RETURN NEW;
END $$;
CREATE FUNCTION speakeremail(integer) RETURNS varchar
    LANGUAGE plpgsql
    AS $_$
DECLARE
  crsr CURSOR FOR SELECT speakers.email, speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
  row RECORD;
  retval VARCHAR;
BEGIN
  retval = NULL;
  FOR row IN crsr LOOP
    retval = concat_ws(', ', retval, row.name || ' <' || row.email || '>');
  END LOOP;
  RETURN retval;
END; $_$;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
CREATE TRIGGER corr_redirect_conflict BEFORE INSERT ON corrections FOR EACH ROW EXECUTE PROCEDURE corrections_redirect();
-- 14 up
ALTER TABLE raw_files ADD stream VARCHAR DEFAULT '' NOT NULL;
ALTER TABLE talks ADD active_stream VARCHAR DEFAULT '' NOT NULL;
-- 14 down
ALTER TABLE raw_files DROP stream;
ALTER TABLE talks DROP active_stream;
-- 15 up
INSERT INTO properties(name) VALUES('serial');
-- 15 down
LOCK TABLE corrections IN SHARE MODE;
DELETE FROM corrections USING properties WHERE corrections.property = properties.id AND properties.name = 'serial';
DELETE FROM properties WHERE name = 'serial';
-- 16 up
INSERT INTO properties(name) VALUES('offset_end');
-- 16 down
LOCK TABLE corrections IN SHARE MODE;
DELETE FROM corrections USING properties WHERE corrections.property = properties.id AND properties.name = 'offset_end';
DELETE FROM properties WHERE name = 'offset_end';
-- 17 up
ALTER TABLE raw_files ADD mtime INTEGER;
-- 17 down
ALTER TABLE raw_files DROP mtime;
-- 18 up
CREATE TABLE config_overrides (
    id SERIAL PRIMARY KEY,
    event integer REFERENCES events(id),
    nodename character varying,
    value character varying NOT NULL
);
-- 18 down
DROP TABLE config_overrides;
-- 19 up
ALTER TABLE users ADD CONSTRAINT users_email_unique UNIQUE (email);
-- 19 down
ALTER TABLE users DROP CONSTRAINT users_email_unique;
-- 20 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'announcing',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 20 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'announcing',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
UPDATE talks SET state='announcing' WHERE state='publishing';
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 21 up
ALTER TABLE talks ADD flags json;
-- 21 down
ALTER TABLE talks DROP flags;
-- 22 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'announcing',
    'done',
    'injecting',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 22 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'announcing',
    'done',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
UPDATE talks SET state='broken' WHERE state='injecting';
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 23 up
ALTER TABLE raw_files ADD CONSTRAINT unique_filename UNIQUE(filename);
ALTER TABLE talks ALTER flags TYPE jsonb;
-- 23 down
ALTER TABLE raw_files DROP CONSTRAINT unique_filename;
ALTER TABLE talks ALTER flags TYPE json;
-- 24 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 24 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'announcing',
    'done',
    'injecting',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
UPDATE talks SET state='publishing' WHERE state IN ('finalreview','removing');
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 25 up
CREATE TABLE commentlog (
    id SERIAL PRIMARY KEY,
    talk integer REFERENCES talks(id),
    comment TEXT,
    state varchar,
    logdate TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT now()
);
INSERT INTO commentlog(talk, comment) SELECT id, comments FROM talks WHERE comments IS NOT NULL;
UPDATE talks SET comments = NULL;
-- 25 down
WITH logtexts(talk, comments) AS
(WITH orderedlog(talk, comment, logdate) AS
(SELECT talk, comment, logdate FROM commentlog ORDER BY logdate)
SELECT talk, string_agg(logdate || E'\n' || comment, E'\n\n') AS comments
FROM orderedlog
GROUP BY talk)
UPDATE talks SET comments = logtexts.comments
FROM logtexts
WHERE talks.id = logtexts.talk;
DROP TABLE commentlog;
-- 26 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'notify_final',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'remove',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 26 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
UPDATE talks SET state='finalreview' WHERE state='notify_final';
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 27 up
ALTER TABLE speakers ADD event INTEGER REFERENCES events(id);
-- 27 down
ALTER TABLE speakers DROP event;
-- 28 up
ALTER TABLE raw_files ADD collection_name VARCHAR;
-- 28 down
DELETE FROM raw_files WHERE collection_name IS NOT NULL;
ALTER TABLE raw_files DROP collection_name;
-- 29 up
ALTER TABLE talks ALTER upstreamid DROP NOT NULL;
-- 29 down
UPDATE talks SET upstreamid=slug WHERE upstreamid IS NULL;
ALTER TABLE talks ALTER upstreamid SET NOT NULL;
-- 30 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'fixuping',
    'uploading',
    'publishing',
    'notify_final',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'remove',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored',
    'uninteresting'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 30 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'uploading',
    'publishing',
    'notify_final',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'remove',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 31 up
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'fixuping',
    'uploading',
    'publishing',
    'notify_final',
    'finalreview',
    'announcing',
    'transcribing',
    'syncing',
    'done',
    'injecting',
    'remove',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored',
    'uninteresting'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 31 down
CREATE TYPE talkstate_new AS ENUM (
    'waiting_for_files',
    'cutting',
    'generating_previews',
    'notification',
    'preview',
    'transcoding',
    'fixuping',
    'uploading',
    'publishing',
    'notify_final',
    'finalreview',
    'announcing',
    'done',
    'injecting',
    'remove',
    'removing',
    'broken',
    'needs_work',
    'lost',
    'ignored',
    'uninteresting'
);
ALTER TABLE talks ALTER state DROP DEFAULT;
ALTER TABLE talks ALTER state TYPE talkstate_new USING(state::varchar)::talkstate_new;
ALTER TABLE talks ALTER state SET DEFAULT 'waiting_for_files';
DROP TYPE talkstate;
ALTER TYPE talkstate_new RENAME TO talkstate;
-- 32 up
ALTER TABLE talks ADD extra_data JSONB;
-- 32 down
ALTER TABLE talks DROP extra_data;
@@ code
-- 1 up
CREATE VIEW last_room_files AS
 SELECT raw_files.filename,
    raw_files.starttime,
    raw_files.endtime,
    date_part('epoch'::text, raw_files.endtime) - date_part('epoch'::text, raw_files.starttime) AS length,
    rooms.name AS room
   FROM raw_files
     JOIN rooms ON raw_files.room = rooms.id
  WHERE ((raw_files.room, raw_files.starttime) IN ( SELECT raw_files_1.room,
            max(raw_files_1.starttime) AS max
           FROM raw_files raw_files_1
          GROUP BY raw_files_1.room));
CREATE VIEW mailers AS
 SELECT speakers.email,
    talks.nonce,
    talks.title
   FROM speakers_talks
     JOIN speakers ON speakers_talks.speaker = speakers.id
     JOIN talks ON speakers_talks.talk = talks.id
  WHERE speakers.email IS NOT NULL;
CREATE VIEW raw_talks AS
 SELECT talks.id AS talkid,
    talks.slug,
    raw_files.id AS rawid,
    raw_files.filename AS raw_filename,
    talks.starttime AS talk_start,
    talks.endtime AS talk_end,
    raw_files.starttime AS raw_start,
    raw_files.endtime AS raw_end,
    talks.endtime - talks.starttime AS talks_length,
    raw_files.endtime - raw_files.starttime AS raw_length,
    LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime) AS raw_length_corrected,
    sum(LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime)) OVER (PARTITION BY talks.id) AS raw_total,
        CASE
            WHEN raw_files.starttime < talks.starttime THEN talks.starttime - raw_files.starttime
            ELSE '00:00:00'::interval
        END AS fragment_start
   FROM talks,
    raw_files
  WHERE (talks.starttime >= raw_files.starttime AND talks.starttime <= raw_files.endtime OR talks.endtime >= raw_files.starttime AND talks.endtime <= raw_files.endtime OR talks.starttime <= raw_files.starttime AND talks.endtime >= raw_files.endtime) AND talks.room = raw_files.room;
CREATE FUNCTION speakerlist(integer) RETURNS varchar
    LANGUAGE plpgsql STABLE
    AS $_$
 DECLARE
   crsr CURSOR FOR SELECT speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
   row RECORD;
   curname speakers.name%TYPE;
   prevname varchar;
   retval varchar;
 BEGIN
   retval=NULL;
   prevname=NULL;
   curname=NULL;
   FOR row IN crsr LOOP
     prevname = curname;
     curname = row.name;
     IF prevname IS NOT NULL THEN
       retval = concat_ws(', ', retval, prevname);
     END IF;
   END LOOP;
   retval = concat_ws(' and ', retval, curname);
   RETURN retval;
 END;
$_$;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
CREATE FUNCTION adjusted_raw_talks(integer, interval, interval) RETURNS SETOF raw_talks LANGUAGE plpgsql AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start,
           talks.endtime + start_off + end_off AS talk_end,
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off)) OVER (range unbounded preceding),
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off THEN talks.starttime + start_off - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval THEN (talks.starttime + start_off - '00:20:00'::interval) - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - '00:20:00'::interval) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off THEN talks.endtime + start_off + end_off - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
CREATE FUNCTION corrections_redirect() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  corrs RECORD;
BEGIN
  FOR corrs IN SELECT * FROM corrections WHERE talk = NEW.talk AND property = NEW.property LOOP
    UPDATE corrections SET property_value = NEW.property_value WHERE talk = NEW.talk AND property = NEW.property;
    RETURN NULL;
  END LOOP;
  RETURN NEW;
END $$;
CREATE FUNCTION speakeremail(integer) RETURNS varchar
    LANGUAGE plpgsql
    AS $_$
DECLARE
  crsr CURSOR FOR SELECT speakers.email, speakers.name FROM speakers JOIN speakers_talks ON speakers.id = speakers_talks.speaker WHERE speakers_talks.talk = $1;
  row RECORD;
  retval VARCHAR;
BEGIN
  retval = NULL;
  FOR row IN crsr LOOP
    retval = concat_ws(', ', retval, row.name || ' <' || row.email || '>');
  END LOOP;
  RETURN retval;
END; $_$;
CREATE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
CREATE TRIGGER corr_redirect_conflict BEFORE INSERT ON corrections FOR EACH ROW EXECUTE PROCEDURE corrections_redirect();
-- 1 down
DROP TRIGGER corr_redirect_conflict ON corrections;
DROP FUNCTION adjusted_raw_talks(integer, interval, interval);
DROP FUNCTION corrections_redirect();
DROP VIEW talk_list;
DROP FUNCTION speakerlist(integer);
DROP FUNCTION speakeremail(integer);
DROP FUNCTION state_next(talkstate);
DROP VIEW last_room_files;
DROP VIEW mailers;
DROP VIEW raw_talks;
-- 2 up
CREATE OR REPLACE VIEW raw_talks AS
 SELECT talks.id AS talkid,
    talks.slug,
    raw_files.id AS rawid,
    raw_files.filename AS raw_filename,
    talks.starttime AS talk_start,
    talks.endtime AS talk_end,
    raw_files.starttime AS raw_start,
    raw_files.endtime AS raw_end,
    talks.endtime - talks.starttime AS talks_length,
    raw_files.endtime - raw_files.starttime AS raw_length,
    LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime) AS raw_length_corrected,
    sum(LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime)) OVER (PARTITION BY talks.id) AS raw_total,
        CASE
            WHEN raw_files.starttime < talks.starttime THEN talks.starttime - raw_files.starttime
            ELSE '00:00:00'::interval
        END AS fragment_start
   FROM talks,
    raw_files
  WHERE (talks.starttime >= raw_files.starttime AND talks.starttime <= raw_files.endtime OR talks.endtime >= raw_files.starttime AND talks.endtime <= raw_files.endtime OR talks.starttime <= raw_files.starttime AND talks.endtime >= raw_files.endtime) AND talks.room = raw_files.room AND talks.active_stream = raw_files.stream;
CREATE OR REPLACE FUNCTION adjusted_raw_talks(integer, interval, interval) RETURNS SETOF raw_talks LANGUAGE plpgsql AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start,
           talks.endtime + start_off + end_off AS talk_end,
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off)) OVER (range unbounded preceding),
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off THEN talks.starttime + start_off - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND talks.active_stream = raw_files.stream
        AND ((talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval THEN (talks.starttime + start_off - '00:20:00'::interval) - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND talks.active_stream = raw_files.stream
        AND ((talks.starttime + start_off - '00:20:00'::interval) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off THEN talks.endtime + start_off + end_off - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND talks.active_stream = raw_files.stream
        AND ((talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
-- 2 down
CREATE OR REPLACE VIEW raw_talks AS
 SELECT talks.id AS talkid,
    talks.slug,
    raw_files.id AS rawid,
    raw_files.filename AS raw_filename,
    talks.starttime AS talk_start,
    talks.endtime AS talk_end,
    raw_files.starttime AS raw_start,
    raw_files.endtime AS raw_end,
    talks.endtime - talks.starttime AS talks_length,
    raw_files.endtime - raw_files.starttime AS raw_length,
    LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime) AS raw_length_corrected,
    sum(LEAST(raw_files.endtime, talks.endtime) - GREATEST(raw_files.starttime, talks.starttime)) OVER (PARTITION BY talks.id) AS raw_total,
        CASE
            WHEN raw_files.starttime < talks.starttime THEN talks.starttime - raw_files.starttime
            ELSE '00:00:00'::interval
        END AS fragment_start
   FROM talks,
    raw_files
  WHERE (talks.starttime >= raw_files.starttime AND talks.starttime <= raw_files.endtime OR talks.endtime >= raw_files.starttime AND talks.endtime <= raw_files.endtime OR talks.starttime <= raw_files.starttime AND talks.endtime >= raw_files.endtime) AND talks.room = raw_files.room;
CREATE OR REPLACE FUNCTION adjusted_raw_talks(integer, interval, interval) RETURNS SETOF raw_talks LANGUAGE plpgsql AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start,
           talks.endtime + start_off + end_off AS talk_end,
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off)) OVER (range unbounded preceding),
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off THEN talks.starttime + start_off - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval THEN (talks.starttime + start_off - '00:20:00'::interval) - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - '00:20:00'::interval) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off)) OVER (range unbounded preceding),
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off THEN talks.endtime + start_off + end_off - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
-- 3 up
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
DECLARE
  enumvals talkstate[];
  startval ALIAS FOR $1;
BEGIN
  IF startval = 'injecting' THEN
    return 'generating_previews'::talkstate;
  ELSE
    IF startval >= 'done' THEN
      return startval;
    ELSE
      enumvals := enum_range(startval, NULL);
      return enumvals[2];
    END IF;
  END IF;
END $_$;
-- 3 down
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
declare
  enumvals talkstate[];
  startval alias for $1;
begin
  enumvals := enum_range(startval, NULL);
  return enumvals[2];
end $_$;
-- 4 up
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    events.outputdir AS event_output,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
-- 4 down
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
-- 5 up
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
DECLARE
    enumvals talkstate[];
    startval ALIAS FOR $1;
BEGIN
  IF startval = 'injecting' THEN
    return 'generating_previews'::talkstate;
  ELSE
    IF startval = 'removing' THEN
      return 'waiting_for_files'::talkstate;
    ELSE
      IF startval >= 'done' THEN
        return startval;
      ELSE
        enumvals := enum_range(startval, NULL);
        return enumvals[2];
      END IF;
    END IF;
  END IF;
END $_$;
-- 5 down
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
DECLARE
  enumvals talkstate[];
  startval ALIAS FOR $1;
BEGIN
  IF startval = 'injecting' THEN
    return 'generating_previews'::talkstate;
  ELSE
    IF startval >= 'done' THEN
      return startval;
    ELSE
      enumvals := enum_range(startval, NULL);
      return enumvals[2];
    END IF;
  END IF;
END $_$;
-- 6 up
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE Plpgsql
    AS $_$
DECLARE
  enumvals talkstate[];
  startval ALIAS FOR $1;
BEGIN
  IF startval = 'injecting' THEN
    return 'generating_previews'::talkstate;
  ELSE
    IF startval = 'remove' THEN
      return 'removing'::talkstate;
    ELSE
      IF startval = 'removing' THEN
        return 'waiting_for_files'::talkstate;
      ELSE
        IF startval >= 'done' THEN
          return startval;
        ELSE
          enumvals := enum_range(startval, NULL);
          return enumvals[2];
        END IF;
      END IF;
    END IF;
  END IF;
END $_$;
-- 6 down
CREATE OR REPLACE FUNCTION state_next(talkstate) RETURNS talkstate
    LANGUAGE plpgsql
    AS $_$
DECLARE
    enumvals talkstate[];
    startval ALIAS FOR $1;
BEGIN
  IF startval = 'injecting' THEN
    return 'generating_previews'::talkstate;
  ELSE
    IF startval = 'removing' THEN
      return 'waiting_for_files'::talkstate;
    ELSE
      IF startval >= 'done' THEN
        return startval;
      ELSE
        enumvals := enum_range(startval, NULL);
        return enumvals[2];
      END IF;
    END IF;
  END IF;
END $_$;
-- 7 up
CREATE FUNCTION adjusted_raw_talks(integer, interval, interval, interval) RETURNS SETOF raw_talks LANGUAGE plpgsql AS $_$
DECLARE
  talk_id ALIAS FOR $1;
  start_off ALIAS FOR $2;
  end_off ALIAS FOR $3;
  audio_margin ALIAS FOR $4;
BEGIN
  RETURN QUERY
    SELECT talk_id AS talkid,
           talks.slug,
           raw_files.id AS rawid,
           raw_files.filename AS raw_filename,
           talks.starttime + start_off AS talk_start, -- the time where the talk starts, after adjustments
           talks.endtime + start_off + end_off AS talk_end, -- the time where the talk ends, after adjustments
           raw_files.starttime AS raw_start,
           raw_files.endtime AS raw_end,
           (talks.endtime + start_off + end_off) - (talks.starttime + start_off) AS talk_length,
           raw_files.endtime - raw_files.starttime AS raw_length,
           LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - audio_margin) AS raw_length_corrected,
           SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - audio_margin)) OVER (range unbounded preceding) AS raw_total,
           CASE
             WHEN raw_files.starttime < talks.starttime + start_off - audio_margin THEN talks.starttime + start_off - audio_margin - raw_files.starttime
             ELSE '00:00:00'::interval
           END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - audio_margin) >= raw_files.starttime AND (talks.starttime + start_off - audio_margin) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off) >= raw_files.starttime AND (talks.endtime + start_off + end_off) <= raw_files.endtime
            OR (talks.starttime + start_off - audio_margin) <= raw_files.starttime AND (talks.endtime + start_off + end_off) >= raw_files.endtime)
      UNION
    SELECT
        -1 AS talkid, -- use -1 to mark that this is the pre video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.starttime + start_off - '00:20:00'::interval AS talk_start,
        talks.starttime + start_off AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval - audio_margin) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.starttime + start_off) - GREATEST(raw_files.starttime, talks.starttime + start_off - '00:20:00'::interval - audio_margin)) OVER (range unbounded preceding) AS raw_total,
        CASE
          WHEN raw_files.starttime < talks.starttime + start_off - '00:20:00'::interval - audio_margin THEN talks.starttime + start_off - '00:20:00'::interval - audio_margin - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.starttime + start_off - '00:20:00'::interval - audio_margin) >= raw_files.starttime AND (talks.starttime + start_off - '00:20:00'::interval - audio_margin) <= raw_files.endtime
            OR (talks.starttime + start_off) >= raw_files.starttime AND (talks.starttime + start_off) <= raw_files.endtime
            OR (talks.starttime + start_off - '00:20:00'::interval - audio_margin) <= raw_files.starttime AND (talks.endtime + start_off) >= raw_files.endtime)
      UNION
    SELECT
        -2 AS talkid, -- use -2 to mark that this is the post video
        talks.slug,
        raw_files.id AS rawid,
        raw_files.filename AS raw_filename,
        talks.endtime + start_off + end_off AS talk_start,
        talks.endtime + start_off + end_off + '00:20:00'::interval AS talk_end,
        raw_files.starttime AS raw_start,
        raw_files.endtime AS raw_end,
        '00:20:00'::interval AS talk_length,
        raw_files.endtime - raw_files.starttime AS raw_length,
        LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off - audio_margin) AS raw_length_corrected,
        SUM(LEAST(raw_files.endtime, talks.endtime + start_off + end_off + '00:20:00'::interval) - GREATEST(raw_files.starttime, talks.endtime + start_off + end_off - audio_margin)) OVER (range unbounded preceding) AS raw_total,
        CASE
          WHEN raw_files.starttime < talks.endtime + start_off + end_off - audio_margin THEN talks.endtime + start_off + end_off - audio_margin - raw_files.starttime
          ELSE '00:00:00'::interval
        END AS fragment_start
      FROM raw_files JOIN rooms ON raw_files.room = rooms.id JOIN talks ON rooms.id = talks.room
      WHERE talks.id = talk_id
        AND ((talks.endtime + start_off + end_off - audio_margin) >= raw_files.starttime AND (talks.endtime + start_off + end_off - audio_margin) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) <= raw_files.endtime
            OR (talks.endtime + start_off + end_off - audio_margin) <= raw_files.starttime AND (talks.endtime + start_off + end_off + '00:20:00'::interval) >= raw_files.endtime);
END $_$;
-- 7 down
DROP FUNCTION adjusted_raw_talks(integer, interval, interval, interval);
-- 8 up
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    events.outputdir AS event_output,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.description,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
-- 8 down
DROP VIEW talk_list;
CREATE VIEW talk_list AS
 SELECT talks.id,
    talks.event AS eventid,
    events.name AS event,
    events.outputdir AS event_output,
    rooms.name AS room,
    rooms.outputname AS room_output,
    speakerlist(talks.id) AS speakers,
    talks.title AS name,
    talks.nonce,
    talks.slug,
    talks.starttime,
    talks.endtime,
    talks.state,
    talks.progress,
    talks.comments,
    rooms.id AS roomid,
    talks.prelen,
    talks.postlen,
    talks.subtitle,
    talks.apologynote,
    tracks.name AS track
   FROM rooms
     LEFT JOIN talks ON rooms.id = talks.room
     LEFT JOIN events ON talks.event = events.id
     LEFT JOIN tracks ON talks.track = tracks.id;
-- 9 down
DROP VIEW mailers;
CREATE VIEW mailers AS
 SELECT speakers.email,
    talks.nonce,
    talks.title
   FROM speakers_talks
     JOIN speakers ON speakers_talks.speaker = speakers.id
     JOIN talks ON speakers_talks.talk = talks.id
  WHERE speakers.email IS NOT NULL;
-- 9 up
DROP VIEW mailers;
CREATE VIEW mailers AS
 SELECT speakers.email,
    talks.nonce,
    talks.title
   FROM speakers_talks
     JOIN speakers ON speakers_talks.speaker = speakers.id
     JOIN talks ON speakers_talks.talk = talks.id
  WHERE speakers.email IS NOT NULL
 UNION
 SELECT tracks.email,
    talks.nonce,
    talks.title
   FROM talks
     JOIN tracks ON talks.track = tracks.id
  WHERE tracks.email IS NOT NULL;
