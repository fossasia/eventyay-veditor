package SReview::Job;

use SReview::Config;
use Scalar::Util qw(weaken);
use Moose;

has 'steps' => (
        is => 'ro',
        isa => 'ArrayRef[SReview::Job::Step]',
        required => 1,
        traits => ['Array'],
        handles => {
                stepcount => 'count',
);

has 'jobid' => (
        is => 'ro',
        isa => 'Str',
        lazy => 1,
        builder => '_load_jobid',
);

has 'talk' => (
        is => 'ro',
        isa => 'SReview::Talk',
        required => 1,
);

sub _load_jobid {
        my $self = shift;

        return join('-', $$, $self->talk->talkid, $self->talk->state);
}

has 'db' => (
        is => 'ro',
        isa => 'DBI::db';
        required => 1,
);

sub run {
        my $self = shift;

        my $db = $self->db;

        my $joblog = $db->prepare("INSERT INTO joblog(talk, jobid) VALUES(?, ?, 0) RETURNING id");
        $joblog->execute($self->talk->talkid, $self->jobid);

        my $row = $joblog->fetchrow_arrayref;
        my $joblog_id = $row->[0];
        my $step_id;

        my $step = $db->prepare("INSERT INTO joblog_step(joblogid, stepname) VALUES(?, ?) RETURNING id");
        my $progress = $db->prepare("UPDATE joblog_step SET progress = ? WHERE id = ?");

        my $talk_steps = $db->prepare("UPDATE talks SET perc=? WHERE id=?");

        sub progress {
                my $perc = shift;

                $progress->execute($perc, $step_id);
        }

        my $done = 0;
        foreach my $step (@{$self->steps}) {
                eval {
                        $step->run(\&progress);
                };
                if($@) {
                        $db->prepare("UPDATE talks SET progress='failed' WHERE id = ?")->execute($self->talk->talkid);
                        die "Step failed: $@";
                }
                $done++;
                $talk_steps->execute($self->done / $self->stepcount, $self->talk->talkid);
        }
}

1;
