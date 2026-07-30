package SReview::Web;

use Mojo::Base 'Mojolicious';
use Mojo::Collection 'c';
use Mojo::JSON qw(encode_json);
use Mojo::Pg;
use Mojo::URL;
use Crypt::PRNG qw/random_string/;
use SReview;
use SReview::Config;
use SReview::Config::Common;
use SReview::Db;
use Media::Convert::Asset;
use Media::Convert::Asset::ProfileFactory;
use SReview::API;
use SReview::Files::Factory;

sub startup {
	my $self = shift;

	my $dir = $ENV{SREVIEW_WDIR};

	SReview::API::init($self);

	my $config = SReview::Config::Common::setup;
	$self->max_request_size(2*1024*1024*1024);

	if(defined($config->get("web_pid_file"))) {
		$self->config(hypnotoad => { pid_file => $config->get("web_pid_file") });
	}

	die "Need to configure secrets!" if $config->get("secret") eq "_INSECURE_DEFAULT_REPLACE_ME_";
	$self->secrets([$config->get("secret")]);

	SReview::Db::init($config);

	if(-d "/usr/share/sreview/templates") {
		push @{$self->renderer->paths}, "/usr/share/sreview/templates";
		push @{$self->static->paths}, "/usr/share/sreview/public";
		push @{$self->static->paths}, "/usr/share/javascript";
	}
	if(-d "public") {
		push @{$self->static->paths}, "./public";
		push @{$self->renderer->paths}, "./templates";
	}
	if(defined($config->get("pubdir"))) {
		push @{$self->static->paths}, $config->get("pubdir");
	}

	$self->hook(before_dispatch => sub {
		my $c = shift;
		my $vpr = $config->get('vid_prefix');
		state $media = undef;
		if(!defined($media)) {
			$media = "media-src 'self'";
			my $url = Mojo::URL->new($vpr);
			if(defined($url->host)) {
				$vpr = $url->host;
				$media = "media-src $vpr";
			}
			if(defined($config->get("finalhosts"))) {
				$media .= " " . $config->get("finalhosts");
			}
			$media .= ";";
		}
		$c->res->headers->content_security_policy("default-src 'none'; connect-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; font-src 'self'; style-src 'self'; img-src 'self' data:; frame-ancestors 'none'; $media");
	});

	$self->helper(dbh => sub {
		state $pg = Mojo::Pg->new->dsn($config->get('dbistring'));
		return $pg->db->dbh;
	});
	$self->helper(srconfig => sub {
		return $config;
	});

	$self->helper(auth_scope => sub {
		my $c = shift;
		my $scope = shift;
		$self->log->debug("checking if authorized for $scope");
		if($c->session->{admin}) {
			return 1;
		} elsif($scope eq "api") {
			return 1;
		} elsif($scope eq "api/event") {
			return 1;
		} elsif($scope eq "api/talks") {
			if(exists($c->session->{id})) {
				return 1;
			}
		} elsif($scope eq "api/talks/detailed") {
			if(exists($c->session->{id})) {
				return 1;
			}
		}
		$self->log->debug("not authorized for $scope");
		return 0;
	});

	$self->helper(talk_update => sub {
		my $c = shift;
		my $talk = shift;
		my $choice = $c->param('choice');
		if(!defined($choice)) {
			die "choice empty";
		} elsif($choice eq "reset") {
			my $sth = $c->dbh->prepare("UPDATE talks SET state='preview', progress='waiting' WHERE id = ?");
			$sth->execute($talk) or die;
		} elsif($choice eq "ok") {
			my $sth = $c->dbh->prepare("UPDATE talks SET state='preview', progress='done' WHERE id = ?");
			$sth->execute($talk) or die;
		} elsif($choice eq 'standard') {
			my $sth = $c->dbh->prepare("SELECT id, name FROM properties");
			$sth->execute();
			while(my $row = $sth->fetchrow_hashref("NAME_lc")) {
				my $name = $row->{name};
				my $parm = $c->param("correction_${name}");
				next unless defined($parm);
				next if (length($parm) == 0);
				my $s = $c->dbh->prepare("INSERT INTO corrections(property_value, talk, property) VALUES (?, ?, ?)");
				$s->execute($parm, $talk, $row->{id}) or die;
			}
			$sth = $c->dbh->prepare("UPDATE talks SET state='waiting_for_files', progress='done' WHERE id = ?");
			$sth->execute($talk) or die;
		} elsif($choice eq "comments") {
			my $sth = $c->dbh->prepare("UPDATE talks SET state='broken', progress='failed', comments = ? WHERE id = ?");
			my $comments = $c->param("comment_text");
			$sth->execute($comments, $talk) or die;
		} else {
			$c->stash(message => "Unknown action.");
			$c->render("error");
			return undef;
		}
		$c->stash(message => 'Update successful.');
	});

	my $eventid = undef;
	$self->helper(eventid => sub {
		if(!defined($eventid)) {
			if(defined($config->get("event"))) {
				my $st = $self->dbh->prepare("SELECT id FROM events WHERE name = ?");
				$st->execute($config->get("event")) or die "Could not find event!\n";
				while(my $row = $st->fetchrow_hashref("NAME_lc")) {
					die if defined($eventid);
					$eventid = $row->{id};
				}
			} else {
				my $st = $self->dbh->prepare("SELECT max(id) AS id FROM events");
				$st->execute() or die "Could not query for events";
				my $row = $st->fetchrow_hashref("NAME_lc");
				$eventid = $row->{id};
			}
		}
		return $eventid;
	});

	$self->helper(version => sub {
		state $rv;
		if(defined $rv) {
			return $rv;
		}
		open GIT, "git describe --tags --dirty 2>/dev/null|";
		$rv = <GIT>;
		close GIT;
		if(!defined $rv) {
			if(exists($ENV{GIT_DESCRIBE})) {
				$rv = $ENV{GIT_DESCRIBE};
			} else {
				if(exists($ENV{OPENSHIFT_BUILD_COMMIT})) {
					$rv = $SReview::VERSION . ", built from commit " . $ENV{OPENSHIFT_BUILD_COMMIT};
				} else {
					$rv = $SReview::VERSION;
				}
			}
		}
		chomp $rv;
		return $rv;
	});

	my $r = $self->routes;
	$r->get('/' => sub {
		my $c = shift;
		$c->render;
	} => 'index');

	$r->get('/login');

	$r->post('/login_post' => sub {
		my $c = shift;

		my $email = $c->param('email');
		my $pass = $c->param('pass');

		my $st = $c->dbh->prepare("SELECT id, isadmin, isvolunteer, name, room FROM users WHERE email=? AND password=crypt(?, password)");
		my $rv;
		if(!($rv = $st->execute($email, $pass))) {
			die "Could not check password: " . $st->errstr;
		}
		if($rv == 0) {
			$c->stash(message => "Incorrect username or password.");
			$c->render('error');
			return undef;
		}
		my $row = $st->fetchrow_arrayref or die "eep?! username query returned nothing\n";
		$c->session->{id} = $row->[0];
		$c->session->{email} = $email;
		$c->session->{admin} = $row->[1];
		$c->session->{volunteer} = $row->[2];
		$c->session->{name} = $row->[3];
		$c->session->{room} = $row->[4];

		if($c->session->{volunteer}) {
			return $c->redirect_to('/volunteer/list');
		} else {
			my $apikey = random_string();
			$c->cookie(sreview_api_key => $apikey);
			$c->session->{apikey} = $apikey;
			return $c->redirect_to('/overview');
		}
	});

	$r->get('/i/:nonce')->to(controller => 'inject', action => 'view', layout => 'default');
	$r->post('/i/:nonce/update')->to(controller => 'inject', action => 'update', layout => 'default');

	$r->get('/r/:nonce')->to(controller => 'review', action => 'view', layout => 'default');
	$r->post('/r/:nonce/update')->to(controller => 'review', layout => 'default', action => 'update');
	$r->get('/r/:nonce/data')->to(controller => 'review', action => 'data');
	$r->get('/f/:nonce')->to(controller => 'finalreview', action => 'view', layout => 'default');
	$r->post('/f/:nonce/update')->to(controller => 'finalreview', action => 'update', layout => 'default');

	$r->get('/released' => sub {
		my $c = shift;
		my $st;
		my $conference = {};
		my $videos = [];
		my %json;
		my %formats;
		my $have_default = 0;
		$st = $c->dbh->prepare("SELECT MIN(starttime::date), MAX(endtime::date) FROM talks WHERE event = ?");
		$st->execute($c->eventid);
		$conference->{title} = $config->get("event");
		my $row = $st->fetchrow_hashref();
		$conference->{date} = [ $row->{min}, $row->{max} ];
		$conference->{video_formats} = {};
		$st = $c->dbh->prepare("SELECT filename FROM raw_files JOIN talks ON raw_files.room = talks.room WHERE talks.event = ? LIMIT 1");
		$st->execute($c->eventid);
		if($st->rows < 1) {
			$c->render(json => {});
			return;
		}
		$row = $st->fetchrow_hashref;
		my $collection = SReview::Files::Factory->create(input => $config->get("inputglob"), $config);
		my $vid = Media::Convert::Asset->new(url => $collection->get_file(relname => $row->{filename})->filename);
		foreach my $format(@{$config->get("output_profiles")}) {
			my $nf;
			$self->log->debug("profile $format");
			my $prof = Media::Convert::Asset::ProfileFactory->create($format, $vid, $self->srconfig->get('extra_profiles'));
			if(!$have_default) {
				$nf = "default";
				$have_default = 1;
			} else {
				$nf = $format;
			}
			my $hash = { vcodec => $prof->video_codec, acodec => $prof->audio_codec, resolution => $prof->video_size, bitrate => $prof->video_bitrate };
			if(!defined($hash->{bitrate})) {
				$hash->{bitrate} = "";
			}
			if($hash->{bitrate} =~ /\d+/) {
				$hash->{bitrate} = $hash->{bitrate} . "k";
			}
			$conference->{video_formats}{$nf} = $hash;
			$formats{$nf} = $prof;
		}
		$json{conference} = $conference;
		$st = $c->dbh->prepare("SELECT talks.id AS talkid, title, subtitle, description, starttime, starttime::date AS date, to_char(starttime, 'yyyy') AS year, endtime, rooms.name AS room, rooms.outputname AS room_output, upstreamid, events.name AS event, slug, events.outputdir AS event_output FROM talks JOIN rooms ON talks.room = rooms.id JOIN events ON talks.event = events.id WHERE state='done' AND event = ?");
		$st->execute($c->eventid);
		if($st->rows < 1) {
			$c->render(json => {});
			return;
		}
		my $mt = Mojo::Template->new;
		$mt->vars(1);
		while (my $row = $st->fetchrow_hashref()) {
			my $video = {};
			my $subtitle = defined($row->{subtitle}) ? " " . $row->{subtitle} : "";
			$video->{title} = $row->{title} . $subtitle;
			$video->{speakers} = SReview::Talk->new(talkid => $row->{talkid})->speakerlist;
			$video->{description} = $row->{description};
			$video->{start} = $row->{starttime};
			$video->{end} = $row->{endtime};
			$video->{room} = $row->{room};
			$video->{eventid} = $row->{upstreamid};
			my @outputdirs;
			SUBDIR:
			foreach my $subdir(@{$config->get('output_subdirs')}) {
				if(!defined($row->{$subdir})) {
					$c->log->info("missing subdir $subdir");
					next SUBDIR;
				}
				push @outputdirs, $row->{$subdir};
			}
			my $outputdir = join('/', @outputdirs);
			if(defined($config->get('eventurl_format'))) {
				$video->{details_url} = $mt->render($config->get('eventurl_format'), {
					slug => $row->{slug},
					room => $row->{room},
					date => $row->{date},
					event => $row->{event},
					event_output => $row->{event_output},
					upstreamid => $row->{upstreamid},
					year => $row->{year} });
				chomp $video->{details_url};
			}
			$video->{video} = join('/',$outputdir, $row->{slug}) . "." . $formats{default}->exten;
			push @$videos, $video;
		}
		$json{videos} = $videos;
		$c->render(json => \%json);
	});

	$r->get('/overview' => sub {
		shift->render;
	});

	$r->get("/credits" => sub {
		shift->render;
	});

	$r->post('/talk_update' => sub {
		my $c = shift;
		my $nonce = $c->param("nonce");
		if(!defined($nonce)) {
			$c->stash(message=>"Unauthorized.");
			$c->res->code(403);
			$c->render('error');
			return undef;
		}
		my $sth = $c->dbh->prepare("SELECT id FROM talks WHERE nonce = ? AND state IN ('preview', 'broken')");
		$sth->execute($nonce);
		my $row = $sth->fetchrow_arrayref;
		if(scalar($row) == 0) {
			$c->stash(message=>"Change not allowed. If this talk exists, it was probably reviewed by someone else while you were doing so too. Please try again later, or check the overview page.");
			$c->res->code(403);
			$c->render('error');
			return undef;
		}
		$c->stash(layout => 'default');
		$c->stash(template => 'talk');
		$c->flash(completion_message => 'Your change has been accepted. Thanks for your help!');
		$c->talk_update($row->[0]);
		$c->redirect_to("/review/$nonce");
	} => 'talk_update');

	my $vol = $r->under('/volunteer' => sub {
		my $c = shift;
		if(!exists($c->session->{id})) {
			$c->redirect_to('/login');
			return 0;
		}
		$c->stash(id => $c->session->{id});
		return 1;
	});

	$vol->get('/list')->to('volunteer#list');

	my $admin = $r->under('/admin' => sub {
		my $c = shift;
		if(!exists($c->session->{id})) {
			$c->res->code(403);
			$c->redirect_to('/login');
			return 0;
		}
		if($c->session->{volunteer}) {
			$c->redirect_to('/volunteer/list');
			return 0;
		}
		$c->stash(layout => "admin");
		$c->stash(admin => $c->session->{admin});
		return 1;
	});

	$admin->any('/schedule/list')->to(controller => 'schedule', action => 'talks');
	$admin->any('/schedule/talk/')->to(controller => 'schedule', action => 'mod_talk');
	$admin->any('/schedule/')->to(controller => 'schedule', action => 'index');

	$admin->get('/')->to('admin#main')->name("admin_talk");

	$admin->get('/logout' => sub {
		my $c = shift;
		delete %{$c->session}{qw/id email admin volunteer name room apikey/};
		# Note, doesn't seem to work in chromium:
		# https://bugs.chromium.org/p/chromium/issues/detail?id=696204
		$c->cookie(sreview_api_key => '', {expires => 0});
		$c->redirect_to('/');
	});

	$admin->get('/talk')->to('review#view');

	$admin->get('/brokens' => sub {
		my $c = shift;
		my $st = $c->dbh->prepare("SELECT talks.id, title, speakeremail(talks.id), tracks.email, comments, state, nonce FROM talks JOIN tracks ON talks.track = tracks.id WHERE state>='broken' ORDER BY state,id");
		my $tst = $c->dbh->prepare("SELECT rooms.altname, count(talks.id) FROM talks JOIN rooms ON talks.room = rooms.id WHERE talks.state='broken' GROUP BY rooms.altname");
		my $rows = [];
		$st->execute;
		$tst->execute;
		$c->stash(title => 'Broken talks');
		$c->stash(titlerow => [ 'id', 'Title', 'Speakers', 'Track email', 'Comments', 'State', 'Link' ]);
		$c->stash(tottitrow => [ 'Room', 'Count' ]);
		my $pgrows = $st->fetchall_arrayref;
		foreach my $row(@{$pgrows}) {
			my $nonce = pop @$row;
			push @$row, "<a href='/r/$nonce'>review</a>";
			push @$rows, $row;
		}
		$c->stash(rows => $rows);
		$c->stash(totals => $tst->fetchall_arrayref);
		$c->stash(header => 'Broken talks');
		$c->stash(layout => 'admin');
		$c->stash(totals => undef);
		$c->stash(autorefresh => 0);
		$c->render(template => 'table');
	} => 'broken_table');

	my $sysadmin = $admin->under('/system' => sub {
		my $c = shift;
		if(!exists($c->session->{id})) {
			$c->res->code(403);
			$c->render(text => 'Unauthorized (not logged on)');
			return 0;
		}
		if(!$c->session->{admin}) {
			$c->res->code(403);
			$c->render(text => 'Unauthorized (not admin)');
			return 0;
		}
		$c->stash(layout => "admin");
		$c->stash(admin => $c->session->{admin});
		return 1;
	});

	$sysadmin->get('/' => sub {
		my $c = shift;
		$c->stash(email => $c->session->{email});
		my $st = $c->dbh->prepare("SELECT DISTINCT rooms.id, rooms.name FROM rooms LEFT JOIN talks ON rooms.id = talks.room WHERE talks.event = ?");
		$st->execute($c->eventid);
		my $rooms = [['All rooms' => '', selected => 'selected']];
		while(my $row = $st->fetchrow_arrayref) {
			push @$rooms, [$row->[1] => $row->[0]];
		}
		$c->stash(rooms => $rooms);
	} => 'admin/dashboard');

	$sysadmin->get('/adduser' => sub {
		my $c = shift;
		open PASSWORD, "pwgen -s 10 -n 1|";
		my $password = <PASSWORD>;
		close(PASSWORD);
		chomp $password;
		my $st = $c->dbh->prepare("INSERT INTO users(email, name, isadmin, isvolunteer, password, room) VALUES(?, ?, ?, ?, crypt(?, gen_salt('bf', 8)), ?)");
		my $room = $c->param('rooms');
		if($room eq "") {
			$room = undef;
		}
		$st->execute($c->param('email'), $c->param('name'), $c->param('isadmin'), $c->param('isvolunteer'), $password, $room) or die;
		$c->dbh->prepare("UPDATE users SET isadmin = false WHERE isadmin is null")->execute;
		$c->flash(msg => "User with email " . $c->param('email') . " created, with password '$password'");
		$c->redirect_to('/admin/system');
	});

	$sysadmin->get('/chpw' => sub {
		my $c = shift;
		my $st = $c->dbh->prepare("SELECT * FROM users WHERE email=?");
		my $email = $c->param("email");
		$st->execute($email);
		if($st->rows != 1) {
			$c->flash(msg => "There is no user with email address " . $c->param('email') . ". Try creating it?");
			$c->redirect_to('/admin/system');
			return;
		}
		open PASSWORD, "pwgen -s 10 -n 1|";
		my $password = <PASSWORD>;
		close(PASSWORD);
		chomp $password;
		$st = $c->dbh->prepare("UPDATE users SET password = crypt(?, gen_salt('bf', 8)) WHERE email = ?");
		$st->execute($password, $email);
		$c->flash(msg => "Password for user $email set to '$password'");
		$c->redirect_to('/admin/system');
	});

	$sysadmin->get('/setpw' => sub {
		my $c = shift;
		my $pw1 = $c->param('password1');
		my $pw2 = $c->param('password2');
		if ($pw1 ne $pw2) {
			$c->flash(msg => "Passwords did not match!");
			$c->redirect_to('/admin/system');
			return;
		}
		my $st = $c->dbh->prepare("UPDATE users SET password = crypt(?, gen_salt('bf', 8)) WHERE email = ?");
		$st->execute($pw1, $c->session->{email});
		$c->flash(msg => "Password changed.");
		$c->redirect_to('/admin/system');
	});

	$r->get('*any' => sub {
		my $c = shift;
		$c->redirect_to('/overview');
	});
}

1;
