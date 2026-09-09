#!/usr/bin/env node
// Regenerate test/fixtures/webidl/interfaces.json — the machine-readable
// WebIDL surface of the specs Dommy implements, distilled from a
// web-platform-tests checkout's `interfaces/*.idl` (which WPT extracts from the
// specs themselves).
//
//   node script/build_webidl_fixture.js <path-to-wpt-checkout>
//
// Uses the webidl2.js bundle vendored in that checkout, so no network or npm
// install is needed. Partials are merged into their interface and `includes`
// mixins are folded in, exactly as a browser's IDL surface would be.
"use strict";

const fs = require("fs");
const path = require("path");

const wpt = process.argv[2];
if (!wpt) {
  console.error("usage: node script/build_webidl_fixture.js <path-to-wpt-checkout>");
  process.exit(1);
}

const WebIDL2 = require(path.join(wpt, "resources/webidl2/lib/webidl2.js"));

// The specs whose interfaces Dommy models. Adding one here widens the audit;
// interfaces Dommy does not implement land in the recorded gap inventory rather
// than failing the suite outright.
// (Web Storage, DOMParser and XMLSerializer live in html.idl, not in a spec
// file of their own.)
const SPECS = [
  "dom", "cssom", "html", "uievents", "url", "FileAPI", "encoding",
  "xhr", "wai-aria", "fetch"
];

const interfaces = new Map(); // name -> record
const includes = [];          // { target, mixin }
const mixins = new Map();     // name -> members

function extendedAttrs(node) {
  const out = {};
  for (const ea of node.extAttrs || []) {
    if (ea.name === "Exposed") {
      const rhs = ea.rhs;
      out.exposed = rhs
        ? (rhs.type === "identifier-list" ? rhs.value.map((v) => v.value) : [rhs.value])
        : [];
    } else {
      out[ea.name] = true;
    }
  }
  return out;
}

// Number of arguments before the first optional / variadic one — WebIDL's
// "required argument count", which is what a function's `length` reports and
// what must throw a TypeError when omitted.
function requiredCount(args) {
  let n = 0;
  for (const a of args || []) {
    if (a.optional || a.variadic) break;
    n++;
  }
  return n;
}

function memberRecord(m) {
  switch (m.type) {
    case "const":
      return { kind: "const", name: m.name, value: m.value && m.value.value };
    case "attribute":
      return { kind: "attribute", name: m.name, static: !!m.special && m.special === "static", readonly: !!m.readonly };
    case "operation":
      if (!m.name) return null; // stringifier / getter / setter / deleter with no name
      return {
        kind: "operation",
        name: m.name,
        static: m.special === "static",
        required: requiredCount(m.arguments),
        total: (m.arguments || []).length
      };
    case "constructor":
      return { kind: "constructor", required: requiredCount(m.arguments), total: (m.arguments || []).length };
    case "iterable":
    case "maplike":
    case "setlike":
    case "async_iterable":
      return { kind: m.type };
    default:
      return null;
  }
}

function record(name, spec) {
  if (!interfaces.has(name)) {
    interfaces.set(name, {
      spec, inherits: null, exposed: null, callback: false,
      legacy_no_interface_object: false, global: false, members: []
    });
  }
  return interfaces.get(name);
}

for (const spec of SPECS) {
  const file = path.join(wpt, "interfaces", spec + ".idl");
  if (!fs.existsSync(file)) {
    console.error("missing IDL: " + file);
    process.exit(1);
  }
  const tree = WebIDL2.parse(fs.readFileSync(file, "utf8"));
  for (const def of tree) {
    if (def.type === "includes") {
      includes.push({ target: def.target, mixin: def.includes });
      continue;
    }
    if (def.type === "interface mixin") {
      const list = mixins.get(def.name) || [];
      for (const m of def.members) {
        const r = memberRecord(m);
        if (r) list.push(r);
      }
      mixins.set(def.name, list);
      continue;
    }
    if (def.type !== "interface" && def.type !== "callback interface") continue;

    const rec = record(def.name, spec);
    const ea = extendedAttrs(def);
    if (!def.partial) {
      rec.inherits = def.inheritance || null;
      rec.callback = def.type === "callback interface";
      rec.legacy_no_interface_object = !!ea.LegacyNoInterfaceObject;
      rec.global = !!ea.Global;
      rec.declared = true;
    }
    // A partial may narrow/extend exposure; the union is what a Window sees.
    if (ea.exposed) rec.exposed = [...new Set([...(rec.exposed || []), ...ea.exposed])];
    for (const m of def.members) {
      const r = memberRecord(m);
      if (r) rec.members.push(r);
    }
  }
}

// Fold `X includes Y` mixin members into X.
for (const { target, mixin } of includes) {
  const rec = interfaces.get(target);
  const members = mixins.get(mixin);
  if (!rec || !members) continue;
  for (const m of members) rec.members.push({ ...m, mixin });
}

// Drop records that only ever appeared as a partial (their real declaration
// lives in a spec outside SPECS) — auditing half an interface is noise.
for (const [name, rec] of interfaces) {
  if (!rec.declared) interfaces.delete(name);
  else delete rec.declared;
}

const sorted = {};
for (const name of [...interfaces.keys()].sort()) {
  const rec = interfaces.get(name);
  const seen = new Set();
  rec.members = rec.members
    .filter((m) => {
      const key = m.kind + ":" + (m.name || "");
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    })
    .sort((a, b) => (a.kind + a.name).localeCompare(b.kind + b.name));
  sorted[name] = rec;
}

let head = "unknown";
try {
  head = require("child_process")
    .execSync("git -C " + JSON.stringify(wpt) + " rev-parse HEAD", { encoding: "utf8" })
    .trim();
} catch (e) { /* a tarball checkout has no git metadata */ }

const out = {
  README:
    "Generated by script/build_webidl_fixture.js from a web-platform-tests " +
    "checkout's interfaces/*.idl. Do not edit by hand.",
  wpt_commit: head,
  specs: SPECS,
  interfaces: sorted
};

const dest = path.join(__dirname, "..", "test/fixtures/webidl/interfaces.json");
fs.mkdirSync(path.dirname(dest), { recursive: true });
fs.writeFileSync(dest, JSON.stringify(out, null, 1) + "\n");
console.log(
  "wrote " + dest + ": " + Object.keys(sorted).length + " interfaces from " + SPECS.length + " specs"
);
