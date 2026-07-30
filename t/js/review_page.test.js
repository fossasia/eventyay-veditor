"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const vm = require("node:vm");

function hasPerlAndMojoTemplate() {
  const r = spawnSync("perl", ["-MMojo::Template", "-e", "1"], {
    encoding: "utf8",
  });
  return r.status === 0;
}

function renderReviewTemplateOrSkip(t) {
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
    "full.html.ep",
  );

  const perlProgram = String.raw`
use strict;
use warnings;
use Mojo::Template;

{
  package Talk;
  sub new {
    my ($class) = @_;
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
      corrections => { serial => 1, audio_channel => 0 },
      comment => "",
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
  sub comment { $_[0]->{comment} }
  sub apology { return '' }
}

sub flash { return undef; }

my $file = shift @ARGV;

my $mt = Mojo::Template->new(vars => 1, namespace => 'main');
my $talk = Talk->new();
my $out = $mt->render_file($file, {
  talk => $talk,
  vid_prefix => '/vid',
  adminspecial => 0,
  template_format => 'svg',
});

die $out if ref $out;
print $out;
`;

  const r = spawnSync("perl", ["-e", perlProgram, templateFile], {
    encoding: "utf8",
    maxBuffer: 10 * 1024 * 1024,
  });

  if (r.status !== 0) {
    throw new Error(`Template render failed: ${r.stderr || r.stdout}`);
  }

  return r.stdout;
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

  // Make slideUp/slideDown/fadeIn/fadeOut synchronous for reliable assertions.
  if ($.fx && Object.prototype.hasOwnProperty.call($.fx, "off")) {
    $.fx.off = true;
  }
  $.fn.slideUp = $.fn.hide;
  $.fn.slideDown = $.fn.show;
  $.fn.fadeOut = $.fn.hide;
  $.fn.fadeIn = $.fn.show;

  // Bootstrap popover is used by the template; we don't test it here.
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

async function tick(window) {
  await new Promise((resolve) => window.setTimeout(resolve, 0));
}

async function runReviewPageInlineScript({ window, $ }, scriptSource) {
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

  vm.runInContext(scriptSource, context, { filename: "review-inline-script.js" });

  // Trigger $(document).ready handlers.
  // jQuery's ready implementation listens for DOMContentLoaded and/or load.
  window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));
  window.dispatchEvent(new window.Event("load"));

  // jQuery may schedule ready callbacks via setTimeout; give it a tick.
  await new Promise((resolve) => window.setTimeout(resolve, 0));
}

function isVisible(window, el) {
  return window.getComputedStyle(el).display !== "none";
}

function getFineControls(window, videoId) {
  return window.document.querySelector(
    `.video-fine-controls[data-video-id="${videoId}"]`,
  );
}

function actionsInOrder(groupEl) {
  return [...groupEl.querySelectorAll("button[data-action]")].map((b) =>
    b.getAttribute("data-action"),
  );
}

function clickAction(window, groupEl, action) {
  const btn = groupEl.querySelector(`button[data-action="${action}"]`);
  assert.ok(btn, `expected button with data-action=${action}`);
  btn.dispatchEvent(new window.Event("click", { bubbles: true }));
}

function getVideoStateOkRadio(window) {
  return window.document.querySelector('input[name="video_state"][value="ok"]');
}

function getVideoStateNotOkRadio(window) {
  return window.document.querySelector(
    'input[name="video_state"][value="not_ok"]',
  );
}

function getPlayPauseButton(window, videoId) {
  return window.document.querySelector(
    `.video-playpause[data-video-id="${videoId}"]`,
  );
}

function getSeekSlider(window, videoId) {
  return window.document.querySelector(
    `.video-seek-slider[data-video-id="${videoId}"]`,
  );
}

function getCurrentTimeEl(window, videoId) {
  return window.document.querySelector(
    `.video-current-time[data-video-id="${videoId}"]`,
  );
}

test("review page: initial state + visibility toggles", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runReviewPageInlineScript({ window, $ }, script);

  const okRadio = window.document.querySelector(
    'input[name="video_state"][value="ok"]',
  );
  const notOkRadio = window.document.querySelector(
    'input[name="video_state"][value="not_ok"]',
  );

  assert.equal(okRadio.checked, true);
  assert.equal(notOkRadio.checked, false);

  // Sections controlled by video_state
  const problemsStart = window.document.getElementById("problems_with_start_time");
  const problemsEnd = window.document.getElementById("problems_with_end_time");
  const soundLegend = [...window.document.querySelectorAll("fieldset.video_has_problems legend")]
    .map((x) => x.textContent.trim());

  assert.equal(isVisible(window, problemsStart), false);
  assert.equal(isVisible(window, problemsEnd), false);
  assert.ok(soundLegend.includes("Sound"));

  // Comment log always visible
  const commentsFs = window.document.querySelector("fieldset.comments");
  assert.equal(isVisible(window, commentsFs), true);

  // Parts above the radio group are visible
  assert.equal(isVisible(window, window.document.getElementById("talk_info")), true);
  assert.equal(isVisible(window, window.document.getElementById("main_video")), true);

  // Toggle to "not_ok" should show problem sections
  $(notOkRadio).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, problemsStart), true);
  assert.equal(isVisible(window, problemsEnd), true);

  // Toggle back to "ok" should hide them again
  $(okRadio).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, problemsStart), false);
  assert.equal(isVisible(window, problemsEnd), false);
});

test("review page: serial==0 disables perfect option + shows help + forces not_ok", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);

  // Ensure serial is 0 (this is the default in the template stub, but keep explicit)
  const serialEl = window.document.getElementById("serial");
  assert.ok(serialEl);
  serialEl.value = "0";

  await runReviewPageInlineScript({ window, $ }, script);

  const okRadio = getVideoStateOkRadio(window);
  const notOkRadio = getVideoStateNotOkRadio(window);
  assert.ok(okRadio);
  assert.ok(notOkRadio);

  assert.equal(okRadio.disabled, true);
  assert.equal(notOkRadio.checked, true);

  const help = window.document.getElementById("video_state_ok_help");
  assert.ok(help);
  assert.equal(help.getAttribute("data-toggle"), "popover");
});

test("review page: serial>0 enables perfect option and hides help", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);

  const serialEl = window.document.getElementById("serial");
  assert.ok(serialEl);
  serialEl.value = "1";

  await runReviewPageInlineScript({ window, $ }, script);

  const okRadio = getVideoStateOkRadio(window);
  assert.ok(okRadio);
  assert.equal(okRadio.disabled, false);

  const help = window.document.getElementById("video_state_ok_help");
  assert.equal(help, null);
});

test("review page: start/end time extra video elements shown/hidden", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runReviewPageInlineScript({ window, $ }, script);

  // First enable problems
  $(window.document.querySelector('input[name="video_state"][value="not_ok"]')).trigger(
    "click",
  );
  await tick(window);

  const startTooEarly = window.document.querySelector(
    'input[name="start_time"][value="too_early"]',
  );
  const startTooLate = window.document.querySelector(
    'input[name="start_time"][value="too_late"]',
  );
  const startOk = window.document.querySelector(
    'input[name="start_time"][value="start_time_ok"]',
  );

  const rowStartEarly = window.document.getElementById("video_starts_too_early");
  const rowStartLate = window.document.getElementById("video_starts_too_late");

  // too early => show main video in start section
  $(startTooEarly).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowStartEarly), true);
  assert.equal(isVisible(window, rowStartLate), false);
  assert.match(
    window.document.getElementById("video-start-early").getAttribute("src"),
    /\/main\./,
  );

  // controls should show/hide along with the row
  assert.equal(
    isVisible(window, getFineControls(window, "video-start-early")),
    true,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-start-late")),
    false,
  );

  // too late => show pre video in start section
  $(startTooLate).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowStartEarly), false);
  assert.equal(isVisible(window, rowStartLate), true);
  assert.match(
    window.document.getElementById("video-start-late").getAttribute("src"),
    /\/pre\./,
  );

  assert.equal(
    isVisible(window, getFineControls(window, "video-start-early")),
    false,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-start-late")),
    true,
  );

  // ok => hide again
  $(startOk).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowStartEarly), false);
  assert.equal(isVisible(window, rowStartLate), false);

  assert.equal(
    isVisible(window, getFineControls(window, "video-start-early")),
    false,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-start-late")),
    false,
  );

  // End time
  const endTooEarly = window.document.querySelector(
    'input[name="end_time"][value="too_early"]',
  );
  const endTooLate = window.document.querySelector(
    'input[name="end_time"][value="too_late"]',
  );
  const endOk = window.document.querySelector(
    'input[name="end_time"][value="end_time_ok"]',
  );

  const rowEndEarly = window.document.getElementById("video_ends_too_early");
  const rowEndLate = window.document.getElementById("video_ends_too_late");

  $(endTooEarly).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowEndEarly), true);
  assert.equal(isVisible(window, rowEndLate), false);
  assert.match(
    window.document.getElementById("video-end-early").getAttribute("src"),
    /\/post\./,
  );

  assert.equal(
    isVisible(window, getFineControls(window, "video-end-early")),
    true,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-end-late")),
    false,
  );

  $(endTooLate).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowEndEarly), false);
  assert.equal(isVisible(window, rowEndLate), true);
  assert.match(
    window.document.getElementById("video-end-late").getAttribute("src"),
    /\/main\./,
  );

  assert.equal(
    isVisible(window, getFineControls(window, "video-end-early")),
    false,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-end-late")),
    true,
  );

  $(endOk).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, rowEndEarly), false);
  assert.equal(isVisible(window, rowEndLate), false);

  assert.equal(
    isVisible(window, getFineControls(window, "video-end-early")),
    false,
  );
  assert.equal(
    isVisible(window, getFineControls(window, "video-end-late")),
    false,
  );
});

test("review page: fine video controls presence/order + seeking behavior", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runReviewPageInlineScript({ window, $ }, script);

  // Enable problems and show a section so handlers are active
  $(window.document.querySelector('input[name="video_state"][value="not_ok"]')).trigger(
    "click",
  );

  // main video will be used as sync reference
  const main = window.document.getElementById("video-main");
  Object.defineProperty(main, "duration", { value: 200, configurable: true });
  Object.defineProperty(main, "currentTime", { value: 42, writable: true, configurable: true });
  main.currentTime = 42;

  function setVideoTimes(id, { duration, currentTime, fps }) {
    const el = window.document.getElementById(id);
    Object.defineProperty(el, "duration", { value: duration, configurable: true });
    Object.defineProperty(el, "currentTime", { value: currentTime, writable: true, configurable: true });
    if (fps != null) el.setAttribute("data-fps", String(fps));
    el.currentTime = currentTime;
    return el;
  }

  function stubPlayPause(el) {
    let paused = true;
    Object.defineProperty(el, "paused", {
      get() {
        return paused;
      },
      configurable: true,
    });
    el.play = () => {
      paused = false;
      el.dispatchEvent(new window.Event("play"));
    };
    el.pause = () => {
      paused = true;
      el.dispatchEvent(new window.Event("pause"));
    };
  }

  const groupStartEarly = getFineControls(window, "video-start-early");
  const groupStartLate = getFineControls(window, "video-start-late");
  const groupEndEarly = getFineControls(window, "video-end-early");
  const groupEndLate = getFineControls(window, "video-end-late");

  assert.ok(groupStartEarly);
  assert.ok(groupStartLate);
  assert.ok(groupEndEarly);
  assert.ok(groupEndLate);

  // Native controls should be disabled for the non-main videos
  [
    "video-start-early",
    "video-start-late",
    "video-end-early",
    "video-end-late",
  ].forEach((id) => {
    const el = window.document.getElementById(id);
    assert.equal(el.hasAttribute("controls"), false);
    assert.ok(getPlayPauseButton(window, id));
    assert.ok(getSeekSlider(window, id));
    assert.ok(getCurrentTimeEl(window, id));
  });

  assert.deepEqual(actionsInOrder(groupStartLate), [
    "reset",
    "rewind-10",
    "rewind-1",
    "rewind-frame",
    "ff-frame",
    "ff-1",
    "ff-10",
    "last-frame",
  ]);

  assert.deepEqual(actionsInOrder(groupStartEarly), [
    "reset",
    "rewind-10",
    "rewind-1",
    "rewind-frame",
    "sync-main",
    "ff-frame",
    "ff-1",
    "ff-10",
    "last-frame",
  ]);

  assert.deepEqual(actionsInOrder(groupEndEarly), [
    "reset",
    "rewind-10",
    "rewind-1",
    "rewind-frame",
    "ff-frame",
    "ff-1",
    "ff-10",
    "last-frame",
  ]);

  assert.deepEqual(actionsInOrder(groupEndLate), [
    "reset",
    "rewind-10",
    "rewind-1",
    "rewind-frame",
    "sync-main",
    "ff-frame",
    "ff-1",
    "ff-10",
    "last-frame",
  ]);

  // Seeking behavior uses 25fps by default
  const v = setVideoTimes("video-start-late", { duration: 100, currentTime: 50, fps: 25 });
  stubPlayPause(v);

  clickAction(window, groupStartLate, "rewind-10");
  assert.equal(v.currentTime, 40);

  clickAction(window, groupStartLate, "rewind-1");
  assert.equal(v.currentTime, 39);

  clickAction(window, groupStartLate, "rewind-frame");
  assert.equal(v.currentTime, 39 - 1 / 25);

  clickAction(window, groupStartLate, "ff-frame");
  assert.equal(v.currentTime, 39);

  clickAction(window, groupStartLate, "ff-1");
  assert.equal(v.currentTime, 40);

  clickAction(window, groupStartLate, "ff-10");
  assert.equal(v.currentTime, 50);

  // reset
  clickAction(window, groupStartLate, "reset");
  assert.equal(v.currentTime, 0);

  // last frame = duration - frameStep
  clickAction(window, groupStartLate, "last-frame");
  assert.equal(v.currentTime, 100 - 1 / 25);

  // sync-main
  const v2 = setVideoTimes("video-start-early", { duration: 100, currentTime: 10, fps: 25 });
  stubPlayPause(v2);
  clickAction(window, groupStartEarly, "sync-main");
  assert.equal(v2.currentTime, 42);

  // play/pause button should toggle play/pause and icon
  const pp = getPlayPauseButton(window, "video-start-late");
  assert.ok(pp);
  const icon = pp.querySelector("i");
  assert.ok(icon);
  assert.match(icon.className, /fa-play/);
  pp.dispatchEvent(new window.Event("click", { bubbles: true }));
  assert.match(icon.className, /fa-pause/);
  pp.dispatchEvent(new window.Event("click", { bubbles: true }));
  assert.match(icon.className, /fa-play/);

  // seek slider should set currentTime approximately
  const slider = getSeekSlider(window, "video-start-late");
  assert.ok(slider);
  slider.value = "500";
  slider.dispatchEvent(new window.Event("input", { bubbles: true }));
  assert.equal(v.currentTime, 50);

  const timeEl = getCurrentTimeEl(window, "video-start-late");
  assert.ok(timeEl);
  assert.match(timeEl.textContent, /^00:50\./);

  // fullscreen should call requestFullscreen on the wrapper
  const fsContainer = v2.closest(".video-fs-container");
  assert.ok(fsContainer);
  let fsCalls = 0;
  fsContainer.requestFullscreen = () => {
    fsCalls += 1;
  };
  const fsBtn = window.document.querySelector(
    '.video-fullscreen[data-video-id="video-start-early"]',
  );
  assert.ok(fsBtn);
  fsBtn.dispatchEvent(new window.Event("click", { bubbles: true }));
  assert.equal(fsCalls, 1);
});

test("review page: av sync seconds input appears when needed", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runReviewPageInlineScript({ window, $ }, script);

  $(window.document.querySelector('input[name="video_state"][value="not_ok"]')).trigger(
    "click",
  );

  const avDelay = window.document.getElementById("av_delay");
  const avOk = window.document.querySelector('input[name="av_sync"][value="av_ok"]');
  const avAudio = window.document.querySelector(
    'input[name="av_sync"][value="av_not_ok_audio"]',
  );
  const avVideo = window.document.querySelector(
    'input[name="av_sync"][value="av_not_ok_video"]',
  );

  assert.equal(isVisible(window, avDelay), false);

  $(avAudio).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, avDelay), true);
  assert.ok(window.document.querySelector('input[name="av_seconds"]'));

  $(avVideo).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, avDelay), true);

  $(avOk).trigger("click");
  await tick(window);
  assert.equal(isVisible(window, avDelay), false);
});

test("review page: start/end offset calculations + overwrite + validation + submit", async (t) => {
  const html = renderReviewTemplateOrSkip(t);
  if (!html) return;

  const script = extractInlineScript(html);
  const { window, $ } = createDom(html);
  await runReviewPageInlineScript({ window, $ }, script);

  // Enable problems
  $(window.document.querySelector('input[name="video_state"][value="not_ok"]')).trigger(
    "click",
  );

  // Make jsdom video elements behave predictably
  function setVideoTimes(id, { duration, currentTime }) {
    const el = window.document.getElementById(id);
    Object.defineProperty(el, "duration", { value: duration, configurable: true });
    Object.defineProperty(el, "currentTime", { value: currentTime, writable: true, configurable: true });
    return el;
  }

  // Start time: too early uses main video currentTime as corrval
  const startTooEarly = window.document.querySelector(
    'input[name="start_time"][value="too_early"]',
  );
  $(startTooEarly).trigger("click");

  const startEarlyVideo = setVideoTimes("video-start-early", { duration: 120, currentTime: 5 });
  startEarlyVideo.currentTime = 5;
  $(window.document.getElementById("start_time_early")).trigger("click");

  assert.equal(window.document.getElementById("start_time_corrval").value, "5");
  assert.match(window.document.getElementById("msg_start_early").innerHTML, /New start time set/);

  // Overwrite with a new selection
  startEarlyVideo.currentTime = 7;
  $(window.document.getElementById("start_time_early")).trigger("click");
  assert.equal(window.document.getElementById("start_time_corrval").value, "7");

  // End time: too early uses post video currentTime as corrval
  const endTooEarly = window.document.querySelector(
    'input[name="end_time"][value="too_early"]',
  );
  $(endTooEarly).trigger("click");

  const endEarlyVideo = setVideoTimes("video-end-early", { duration: 120, currentTime: 8 });
  endEarlyVideo.currentTime = 8;
  $(window.document.getElementById("end_time_early")).trigger("click");

  assert.equal(window.document.getElementById("end_time_corrval").value, "8");
  // Ensure start corrval remains as set earlier
  assert.equal(window.document.getElementById("start_time_corrval").value, "7");

  // Validation: selecting a start point that would create < 1 minute duration should error and not store.
  // Current end offset is +8s (=> new_end 00:02:08). Set start offset to +80s => duration 48s.
  startEarlyVideo.currentTime = 80;
  $(window.document.getElementById("start_time_early")).trigger("click");

  assert.match(
    window.document.getElementById("err_start_early").innerHTML,
    /Video length must be at least 1 minute/,
  );
  // Corrval should still be the previous valid value
  assert.equal(window.document.getElementById("start_time_corrval").value, "7");

  // Submit should include offsets when valid and not be prevented.
  // Re-set to a valid start offset.
  startEarlyVideo.currentTime = 10;
  $(window.document.getElementById("start_time_early")).trigger("click");
  assert.equal(window.document.getElementById("start_time_corrval").value, "10");

  const form = window.document.getElementById("main_form");
  const submitEvent = new window.Event("submit", { cancelable: true });
  const ok = form.dispatchEvent(submitEvent);
  assert.equal(ok, true);
  assert.equal(submitEvent.defaultPrevented, false);

  assert.equal(window.document.getElementById("start_time_corrval").value, "10");
  assert.equal(window.document.getElementById("end_time_corrval").value, "8");
});
