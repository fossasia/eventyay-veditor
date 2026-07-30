"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

function hasPerlAndMojoTemplate() {
  const r = spawnSync("perl", ["-MMojo::Template", "-e", "1"], {
    encoding: "utf8",
  });
  return r.status === 0;
}

function renderNewreviewTemplateOrSkip(t, { corrections } = {}) {
  if (!hasPerlAndMojoTemplate()) {
    t.skip("perl or Mojo::Template not available");
    return null;
  }

  const templateFile = path.join(
    __dirname,
    "..",
    "..",
    "web",
    "templates",
    "review",
    "update.html+newreview.ep",
  );

  const correctionsJson = JSON.stringify(corrections || {});

  const perlProgram = String.raw`
use strict;
use warnings;
use Mojo::Template;
use JSON::MaybeXS qw/decode_json/;

{
  package Talk;
  sub new {
    my ($class) = @_;
    return bless {
      eventname => 'Event',
      title => 'Title',
    }, $class;
  }
  sub eventname { $_[0]->{eventname} }
  sub title { $_[0]->{title} }
}

my $file = shift @ARGV;
my $corrections_json = shift @ARGV;
my $corrections = decode_json($corrections_json);

my $mt = Mojo::Template->new(vars => 1, namespace => 'main');
my $talk = Talk->new();
my $out = $mt->render_file($file, {
  talk => $talk,
  corrections => $corrections,
});

die $out if ref $out;
print $out;
`;

  const r = spawnSync("perl", ["-e", perlProgram, templateFile, correctionsJson], {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  if (r.status !== 0) {
    throw new Error(`Template render failed: ${r.stderr || r.stdout}`);
  }

  return r.stdout;
}

test("newreview page: shows audio channel line only when present in corrections", (t) => {
  const html = renderNewreviewTemplateOrSkip(t, {
    corrections: { audio_channel: 2 },
  });
  if (!html) return;

  assert.match(html, /The audio channel should be changed to channel 2/);
});

test("newreview page: funny message when no effective changes", (t) => {
  const html = renderNewreviewTemplateOrSkip(t, { corrections: {} });
  if (!html) return;

  assert.match(html, /You said there were problems, but you didn't ask us to change anything\./);
  assert.doesNotMatch(html, /The audio channel should be changed to channel/);
});
