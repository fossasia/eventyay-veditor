"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function loadOverview({ cookie = "" } = {}) {
  const filename = path.join(__dirname, "..", "..", "web", "public", "overview.js");
  const code = fs.readFileSync(filename, "utf8");

  const fetchCalls = [];
  function fetchStub(url, _options) {
    fetchCalls.push({ url, options: _options });
    if (url === "/api/v1/config") {
      return Promise.resolve({
        json: () => Promise.resolve({ event: "E1" }),
      });
    }
    if (url === "/api/v1/event/list") {
      return Promise.resolve({
        json: () => Promise.resolve(["E1", "E2"]),
      });
    }
    if (url === "/api/v1/config/legend/") {
      return Promise.resolve({
        json: () => Promise.resolve([{ name: "waiting", expl: "Waiting" }]),
      });
    }
    if (url === "/api/v1/room/list") {
      return Promise.resolve({
        json: () => Promise.resolve(["R1"]),
      });
    }
    if (url.startsWith("/api/v1/event/") && url.endsWith("/overview")) {
      return Promise.resolve({
        json: () =>
          Promise.resolve([
            {
              name: "Talk",
              speakers: "Alice",
              starttime: "2020-01-01T10:00:00",
              endtime: "2020-01-01T11:00:00",
              room: "R1",
              track: "T1",
              state: "waiting",
              progress: "waiting",
            },
          ]),
      });
    }
    if (url === "/api/v1/config/legend") {
      return Promise.resolve({
        json: () => Promise.resolve([{ name: "waiting" }]),
      });
    }
    if (url === "/api/v1/track/list") {
      return Promise.resolve({
        json: () => Promise.resolve(["T1"]),
      });
    }

    if (url.startsWith("/api/v1/speaker/search/")) {
      return Promise.resolve({
        json: () => Promise.resolve([{ id: 1, name: "Alice", event: "E1" }]),
      });
    }

    return Promise.reject(new Error(`Unexpected fetch url: ${url}`));
  }

  const jqueryStub = function jqueryStub() {
    const api = {
      show: () => api,
      hide: () => api,
      scrollTop: () => api,
    };
    return api;
  };

  const VueStub = function VueStub(options) {
    const initialData = typeof options.data === "function" ? options.data() : options.data;
    const inst = Object.assign({}, initialData);

    if (options.methods) {
      for (const [name, fn] of Object.entries(options.methods)) {
        inst[name] = fn.bind(inst);
      }
    }

    // Preserve options for tests that want to introspect them.
    inst.__options = options;

    if (typeof options.created === "function") {
      options.created.call(inst);
    }

    return inst;
  };

  VueStub.component = function componentStub(_name, definition) {
    return definition;
  };

  const context = vm.createContext({
    console,
    Date,
    fetch: fetchStub,
    document: { cookie },
    Vue: VueStub,
    $: jqueryStub,
  });

  const exportCode = `\n;globalThis.__overview_exports = { unique_filter, validate_timestamp, search_text, filter_talks, blank_talk_edit_modal_data, validate_edit_talk, load_event, vm, auth_fetch, filter_component, talk_edit_modal_component };`;
  vm.runInContext(code + exportCode, context, { filename });

  return {
    exports: context.__overview_exports,
    fetchCalls,
    context,
  };
}

test("overview.js: validate_timestamp rejects obvious invalid cases", () => {
  const { exports } = loadOverview();
  const { validate_timestamp } = exports;

  assert.equal(validate_timestamp(""), false);
  assert.equal(validate_timestamp(null), false);
  assert.equal(validate_timestamp("2020-01-01"), false);
  assert.equal(validate_timestamp("not a date at all"), false);
});

test("overview.js: validate_timestamp accepts ISO-ish strings", () => {
  const { exports } = loadOverview();
  const { validate_timestamp } = exports;

  assert.equal(validate_timestamp("2020-01-01T00:00"), true);
  assert.equal(validate_timestamp("2020-01-01T00:00:00.000Z"), true);
});

test("overview.js: unique_filter only keeps first occurrence", () => {
  const { exports } = loadOverview();
  const { unique_filter } = exports;

  const a = ["x", "y", "x", "z", "y"].filter(unique_filter);
  assert.deepEqual(a, ["x", "y", "z"]);
});

test("overview.js: search_text matches on name and speakers", () => {
  const { exports } = loadOverview();
  const { search_text } = exports;

  const talk = { name: "My Talk", speakers: "Alice Bob" };
  assert.equal(search_text("talk", talk), true);
  assert.equal(search_text("alice", talk), true);
  assert.equal(search_text("charlie", talk), false);
});

test("overview.js: filter_talks combines search + multiple filters", () => {
  const { exports } = loadOverview();
  const { filter_talks, vm: vmInst } = exports;

  vmInst.talks = [
    {
      name: "N1",
      speakers: "Alice",
      starttime_date: "2020-01-01",
      room: "R1",
      track: "T1",
      state: "waiting",
      progress: "waiting",
    },
    {
      name: "N2",
      speakers: "Bob",
      starttime_date: "2020-01-02",
      room: "R2",
      track: "T2",
      state: "done",
      progress: "done",
    },
  ];

  vmInst.search = "alice";
  vmInst.selected_dates = ["2020-01-01", "2020-01-02"];
  vmInst.selected_rooms = ["R1", "R2"];
  vmInst.selected_tracks = ["T1", "T2"];
  vmInst.selected_states = ["waiting", "done"];
  vmInst.selected_progresses = ["waiting", "done"];

  filter_talks();
  assert.equal(vmInst.rows.length, 1);
  assert.equal(vmInst.rows[0].name, "N1");

  // Now exclude by room
  vmInst.selected_rooms = ["R2"];
  filter_talks();
  assert.equal(vmInst.rows.length, 0);
});

test("overview.js: blank_talk_edit_modal_data has stable defaults", () => {
  const { exports } = loadOverview();
  const { blank_talk_edit_modal_data } = exports;

  const x = blank_talk_edit_modal_data();
  assert.equal(x.valid, false);
  assert.equal(x.progress, "waiting");
  assert.equal(x.state, "waiting_for_files");
  // x.speakers originates from another VM context; assert on shape instead of deepStrictEqual.
  assert.equal(Array.isArray(x.speakers), true);
  assert.equal(x.speakers.length, 0);
});

test("overview.js: validate_edit_talk sets .valid based on required fields", () => {
  const { exports } = loadOverview();
  const { validate_edit_talk } = exports;

  const obj = {
    title: "T",
    valid_starttime: true,
    valid_endtime: true,
    room: "R",
    valid: false,
  };

  validate_edit_talk.call(obj);
  // validate_edit_talk uses JS truthiness, so obj.valid may become a non-boolean truthy value.
  assert.ok(obj.valid);

  obj.room = null;
  validate_edit_talk.call(obj);
  assert.ok(!obj.valid);
});

test("overview.js: load_event populates vm.talks and derived unique lists", async () => {
  const { exports } = loadOverview();
  const { load_event, vm: vmInst } = exports;

  vmInst.event = "E1";
  load_event();

  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(vmInst.talks.length, 1);
  assert.equal(vmInst.talks[0].starttime_date, "2020-01-01");
  assert.equal(vmInst.days[0], "2020-01-01");
  assert.equal(vmInst.rooms[0], "R1");
  assert.equal(vmInst.tracks[0], "T1");
  assert.equal(vmInst.states[0], "waiting");
  assert.equal(vmInst.progresses[0], "waiting");
});

test("overview.js: admin cookie enables auth_fetch and clears cookie on 401", async () => {
  const filename = path.join(__dirname, "..", "..", "web", "public", "overview.js");
  const code = fs.readFileSync(filename, "utf8");

  const cookieStore = { cookie: "sreview_api_key=KEY" };
  const calls = [];
  function fetchStub(url, options) {
    calls.push({ url, options });

    if (url === "/api/v1/config") {
      return Promise.resolve({ json: () => Promise.resolve({ event: "E1" }) });
    }
    if (url === "/api/v1/event/list") {
      return Promise.resolve({ json: () => Promise.resolve(["E1"]) });
    }
    if (url === "/api/v1/config/legend/") {
      return Promise.resolve({ json: () => Promise.resolve([]) });
    }
    // Force auth_fetch wrapper to install (auth_fetch != fetch) by allowing /track/list.
    if (url === "/api/v1/track/list") {
      return Promise.resolve({ json: () => Promise.resolve([]) });
    }
    if (url.startsWith("/protected")) {
      return Promise.resolve({
        status: 401,
        json: () => Promise.resolve({}),
      });
    }
    // Default minimal stubs used by mounted hooks if called.
    if (url === "/api/v1/room/list") {
      return Promise.resolve({ json: () => Promise.resolve([]) });
    }
    if (url === "/api/v1/config/legend") {
      return Promise.resolve({ json: () => Promise.resolve([]) });
    }

    return Promise.resolve({ status: 200, json: () => Promise.resolve({}) });
  }

  const jqueryStub = function jqueryStub() {
    const api = {
      show: () => api,
      hide: () => api,
      scrollTop: () => api,
    };
    return api;
  };

  const VueStub = function VueStub(options) {
    const initialData = typeof options.data === "function" ? options.data() : options.data;
    const inst = Object.assign({}, initialData);
    if (options.methods) {
      for (const [name, fn] of Object.entries(options.methods)) {
        inst[name] = fn.bind(inst);
      }
    }
    if (typeof options.created === "function") {
      options.created.call(inst);
    }
    return inst;
  };
  VueStub.component = function componentStub(_name, definition) {
    return definition;
  };

  const context = vm.createContext({
    console,
    Date,
    fetch: fetchStub,
    document: cookieStore,
    Vue: VueStub,
    $: jqueryStub,
  });

  const exportCode = `\n;globalThis.__overview_exports = { vm, auth_fetch };`;
  vm.runInContext(code + exportCode, context, { filename });

  // Give created() a tick to run its fetch chains.
  await new Promise((resolve) => setTimeout(resolve, 0));

  // auth_fetch should add X-SReview-Key.
  await context.__overview_exports.auth_fetch("/protected", {}).catch(() => {});
  assert.equal(calls[calls.length - 1].options.headers["X-SReview-Key"], "KEY");

  // On 401, cookie is cleared.
  assert.match(cookieStore.cookie, /^sreview_api_key=;/);
});

test("overview.js: navbar-filter select_all/select_none toggles checkboxes", () => {
  const { exports } = loadOverview();
  const { filter_component } = exports;

  const inst = {
    checkboxes: [
      { checked: false, value: "A" },
      { checked: true, value: "B" },
    ],
  };

  filter_component.methods.select_all.call(inst);
  assert.equal(inst.checkboxes.every((o) => o.checked), true);

  filter_component.methods.select_none.call(inst);
  assert.equal(inst.checkboxes.every((o) => !o.checked), true);
});

test("overview.js: navbar-filter options + checkboxes watchers emit selection and update flags", () => {
  const { exports } = loadOverview();
  const { filter_component } = exports;

  const emitted = [];
  const inst = {
    id: "navbar-filter-123",
    selected_all: true,
    selected_none: false,
    checkboxes: [],
    $emit: (name, payload) => emitted.push({ name, payload }),
  };

  filter_component.watch.options.call(inst, ["A", null]);
  assert.equal(inst.checkboxes.length, 2);
  assert.equal(inst.checkboxes[0].checked, true);
  assert.equal(inst.checkboxes[1].name, "None");

  // Uncheck one and run handler
  inst.checkboxes[0].checked = false;
  filter_component.watch.checkboxes.handler.call(inst, inst.checkboxes);
  assert.deepEqual(emitted[0], { name: "update:selected", payload: [null] });
  assert.equal(inst.selected_all, false);
  assert.equal(inst.selected_none, false);

  // Uncheck all => selected_none
  inst.checkboxes[1].checked = false;
  filter_component.watch.checkboxes.handler.call(inst, inst.checkboxes);
  assert.equal(inst.selected_none, true);
});

test("overview.js: talk-edit-modal basic methods + watcher logic", async () => {
  const { exports, fetchCalls } = loadOverview();
  const { talk_edit_modal_component } = exports;

  const inst = Object.assign(
    {
      nonce: undefined,
      new_talk: false,
      visible: false,
      $emit: function emitNoop() {},
    },
    talk_edit_modal_component.data(),
  );

  // update_visibility should toggle visible state
  talk_edit_modal_component.methods.update_visibility.call(inst);
  assert.equal(inst.visible, false);
  inst.nonce = "N1";
  talk_edit_modal_component.methods.update_visibility.call(inst);
  assert.equal(inst.visible, true);

  // add/remove speaker
  talk_edit_modal_component.methods.add_speaker.call(inst, { id: 1 });
  talk_edit_modal_component.methods.add_speaker.call(inst, { id: 2 });
  assert.equal(inst.speakers.length, 2);
  talk_edit_modal_component.methods.remove_speaker.call(inst, 1);
  assert.equal(inst.speakers.length, 1);
  assert.equal(inst.speakers[0].id, 2);

  // watcher: starttime/endtime propagate validity
  talk_edit_modal_component.watch.starttime.call(inst, "2020-01-01T00:00:00.000Z");
  talk_edit_modal_component.watch.endtime.call(inst, "2020-01-01T00:10:00.000Z");
  assert.equal(inst.valid_starttime, true);
  assert.equal(inst.valid_endtime, true);

  // watcher: speaker_search fetches only when >= 3
  inst.speaker_search_results = ["x"];
  talk_edit_modal_component.watch.speaker_search.call(inst, "ab");
  // speaker_search_results originates from another VM context; assert on shape.
  assert.equal(Array.isArray(inst.speaker_search_results), true);
  assert.equal(inst.speaker_search_results.length, 0);
  talk_edit_modal_component.watch.speaker_search.call(inst, "abc");

  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.ok(fetchCalls.some((c) => c.url.startsWith("/api/v1/speaker/search/")));
});

