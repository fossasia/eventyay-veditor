"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const vm = require("node:vm");

function hasPerlAndMojoTemplate() {
  const r = spawnSync("perl", ["-MMojo::Template", "-e", "1"], {
    encoding: "utf8",
  });
  return r.status === 0;
}

function renderConfirmTemplateOrSkip(t) {
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
    "confirm.html.ep",
  );

  const perlProgram = String.raw`
use strict;
use warnings;
use Mojo::Template;

{
  package Talk;
  sub new {
    my ($class, $serial) = @_;
    return bless {
      nonce => 'NONCE',
      eventname => 'Event',
      title => 'Title',
      speakers => 'Speakers',
      readable_date => '2020-01-01',
      room => 'Room',
      relative_name => 'relname',
      preview_exten => 'mp4',
      state => 'preview',
      corrections => { serial => $serial, audio_channel => 0 },
    }, $class;
  }
  sub nonce { $_[0]->{nonce} }
  sub eventname { $_[0]->{eventname} }
  sub title { $_[0]->{title} }
  sub speakers { $_[0]->{speakers} }
  sub readable_date { $_[0]->{readable_date} }
  sub room { $_[0]->{room} }
  sub relative_name { $_[0]->{relative_name} }
  sub preview_exten { $_[0]->{preview_exten} }
  sub state { $_[0]->{state} }
  sub corrections { $_[0]->{corrections} }
  sub apology { return '' }
}

sub flash { return undef; }

my $file = shift @ARGV;
my $serial = shift @ARGV;

my $mt = Mojo::Template->new(vars => 1, namespace => 'main');
my $talk = Talk->new($serial);
my $out = $mt->render_file($file, {
  talk => $talk,
  vid_prefix => '/vid',
  adminspecial => 0,
  template_format => 'svg',
});

die $out if ref $out;
print $out;
`;

  const r = spawnSync("perl", ["-e", perlProgram, templateFile, "1"], {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  if (r.status !== 0) {
    throw new Error(`Template render failed: ${r.stderr || r.stdout}`);
  }

  return {
    htmlSerial1: r.stdout,
    renderWithSerial: (serial) => {
      const r2 = spawnSync("perl", ["-e", perlProgram, templateFile, String(serial)], {
        encoding: "utf8",
        maxBuffer: 10 * 1024 * 1024,
      });
      if (r2.status !== 0) {
        throw new Error(`Template render failed: ${r2.stderr || r2.stdout}`);
      }
      return r2.stdout;
    },
  };
}

function extractInlineScript(html) {
  const matches = [...html.matchAll(/<script>([\s\S]*?)<\/script>/gi)];
  assert.ok(matches.length > 0, "expected at least one <script> in template");
  return matches[matches.length - 1][1];
}

function createDom(html) {
  const { JSDOM } = require("jsdom");

  const dom = new JSDOM(html, {
    url: "http://localhost/",
    runScripts: "outside-only",
    pretendToBeVisual: true,
  });

  const window = dom.window;
  const $ = require("jquery")(window);

  if ($.fx && Object.prototype.hasOwnProperty.call($.fx, "off")) {
    $.fx.off = true;
  }
  $.fn.slideUp = $.fn.hide;
  $.fn.slideDown = $.fn.show;
  $.fn.fadeOut = $.fn.hide;
  $.fn.fadeIn = $.fn.show;

  // Bootstrap popover is used by the template; we only ensure code doesn't explode.
  $.fn.popover = function popoverNoop() {
    return this;
  };

  // Avoid async/network.
  $.getJSON = function getJSONStub(_url, cb) {
    cb({
      start_iso: "2020-01-01T00:00:00.000Z",
      end_iso: "2020-01-01T00:02:00.000Z",
    });
  };

  return { dom, window, $ };
}

async function runInlineScript({ window, $ }, scriptSource) {
  const context = vm.createContext({
    window,
    document: window.document,
    $,
    jQuery: $,
    Intl: window.Intl,
    Date: window.Date,
    setTimeout: window.setTimeout.bind(window),
    clearTimeout: window.clearTimeout.bind(window),
  });

  vm.runInContext(scriptSource, context, { filename: "confirm-inline-script.js" });

  window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));
  window.dispatchEvent(new window.Event("load"));

  await new Promise((resolve) => window.setTimeout(resolve, 0));
}

function isDisabled(el) {
  return !!el.disabled;
}

test("confirm page: serial>0 keeps ok enabled", async (t) => {
  const rendered = renderConfirmTemplateOrSkip(t);
  if (!rendered) return;

  const html = rendered.renderWithSerial(1);
  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runInlineScript({ window, $ }, script);

  const okRadio = window.document.querySelector('input[name="video_state"][value="ok"]');
  assert.ok(okRadio);
  assert.equal(isDisabled(okRadio), false);
});

test("confirm page: serial<=0 disables ok and auto-selects not_ok", async (t) => {
  const rendered = renderConfirmTemplateOrSkip(t);
  if (!rendered) return;

  const html = rendered.renderWithSerial(0);
  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runInlineScript({ window, $ }, script);

  const okRadio = window.document.querySelector('input[name="video_state"][value="ok"]');
  const notOkRadio = window.document.querySelector('input[name="video_state"][value="not_ok"]');
  assert.ok(okRadio);
  assert.ok(notOkRadio);

  assert.equal(isDisabled(okRadio), true);
  assert.equal(okRadio.checked, false);
  assert.equal(notOkRadio.checked, true);

  const help = window.document.getElementById("video_state_ok_help");
  assert.ok(help);
});
