#!/usr/bin/perl -w

use strict;
use warnings;

use Test::More;
use_ok("SReview::Schedule::Yaml");

my $parser = SReview::Schedule::Yaml->new(url => "file://./t/testvids/schedule.yaml");

ok(scalar(@{$parser->events}) == 1, "we parsed exactly one event");
my $event = $parser->events->[0];
ok(scalar(@{$event->talks}) == 3, "we parsed 3 talks");
my $talks = $event->talks;

ok($talks->[0]->title eq "Test talk", "the test talk was parsed correctly");

done_testing;
