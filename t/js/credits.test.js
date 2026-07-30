"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("credits.js: talk-preview component setForce updates force", () => {
  const filename = path.join(__dirname, "..", "..", "web", "public", "credits.js");
  const code = fs.readFileSync(filename, "utf8");

  const fetchCalls = [];
  function fetchStub(url) {
    fetchCalls.push(url);
    if (typeof url === "string" && url.startsWith("/api/v1/nonce/")) {
      return Promise.resolve({
        headers: {
          get: (name) => (name && name.toLowerCase() === "content-type" ? "image/png" : null),
        },
      });
    }
    if (url === "/api/v1/config") {
      return Promise.resolve({ json: () => Promise.resolve({ event: "E1" }) });
    }
    if (url === "/api/v1/event/list") {
      return Promise.resolve({ json: () => Promise.resolve(["E1"]) });
    }
    if (url.startsWith("/api/v1/event/") && url.endsWith("/overview")) {
      return Promise.resolve({
        json: () =>
          Promise.resolve([
            { state: "ignored" },
            { state: "preview", nonce: "N", title: "T" },
          ]),
      });
    }
    return Promise.reject(new Error(`Unexpected fetch url: ${url}`));
  }

  const createdComponents = new Map();
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
  VueStub.component = function componentStub(name, definition) {
    createdComponents.set(name, definition);
    return definition;
  };

  const context = vm.createContext({
    console,
    Date,
    fetch: fetchStub,
    Vue: VueStub,
  });

  vm.runInContext(code + "\n;globalThis.__credits_exports = { app };", context, {
    filename,
  });

  const talkPreview = createdComponents.get("talk-preview");
  assert.ok(talkPreview);

  // Simulate component instance
  const inst = talkPreview.data();
  const before = inst.force;
  assert.equal(before, false);

  // Provide deterministic Date.now
  const origNow = Date.now;
  Date.now = () => 1234;
  try {
    talkPreview.methods.setForce.call(inst);
  } finally {
    Date.now = origNow;
  }

  assert.equal(inst.force, 1234);

  // Ensure created hook in app triggers fetches for config + event/list
  assert.ok(fetchCalls.includes("/api/v1/config"));
  assert.ok(fetchCalls.includes("/api/v1/event/list"));
});
