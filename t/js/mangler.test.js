"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const loadMangler = function() {
  const filename = path.join(__dirname, "..", "..", "web", "public", "mangler.js");
  const code = fs.readFileSync(filename, "utf8");

  globalThis.sreview_viddata = {
    corrvals: {
      length_adj: 0,
      offset_start: 2,
    },
    prelen: 10,
    mainlen: 100,
    postlen: 3,
  };

  vm.runInThisContext(code, { filename });

  return globalThis.sreview_viddata;
};

test("mangler.js: init sets startpoints/newpoints", () => {
  const vid = loadMangler();

  assert.equal(vid.current_length_adj, 0);
  assert.equal(vid.current_offset, 2);

  assert.deepEqual(vid.lengths, {
    pre: 10,
    main_initial: 100,
    post: 3,
  });

  assert.deepEqual(vid.startpoints, {
    pre: 0,
    main: 12,
    post: 112,
  });

  assert.deepEqual(vid.newpoints, {
    start: 12,
    end: 112,
  });
});

test("mangler.js: conversions are consistent", () => {
  const vid = loadMangler();

  // main start offset should be corrvals.offset_start
  assert.equal(vid.get_start_offset(), 2);

  // point_to_abs: where + startpoints[which]
  assert.equal(vid.point_to_abs("main", 0), 12);
  assert.equal(vid.point_to_abs("post", 0), 112);

  // abs_to_offset: abs - startpoints.main + current_offset
  assert.equal(vid.abs_to_offset(12), 2);
  assert.equal(vid.abs_to_offset(13), 3);

  // set point and read back derived values
  vid.set_point("main", "start", 5);
  assert.equal(vid.newpoints.start, 17);
  assert.equal(vid.get_start_offset(), 7);

  vid.set_point("post", "end", 8);
  // end = post start (112) + 8 = 120; newlen = 120 - 17 = 103; adj = 103 - 100 = 3
  assert.equal(vid.newpoints.end, 120);
  assert.equal(vid.get_length_adjust(), 3);
});

test("mangler.js: setters update points", () => {
  const vid = loadMangler();

  vid.set_start_offset(7);
  assert.equal(vid.newpoints.start, 19);

  vid.set_length_adj(4);
  assert.equal(vid.newpoints.end, 19 + 100 + 4);
  assert.equal(vid.get_length_adjust(), 4);
});
