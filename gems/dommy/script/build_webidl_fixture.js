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
//
// pointerevents, touch-events, css-animations, css-transitions and fullscreen
// are here for the event handler IDL attributes they add to
// GlobalEventHandlers / Element / Document (onpointerdown, ontouchstart,
// onanimationend, ontransitionend, onfullscreenchange), which
// script/build_event_handlers.rb turns into the event handler tables.
const SPECS = [
  "dom", "cssom", "html", "uievents", "url", "FileAPI", "encoding",
  "xhr", "wai-aria", "fetch", "streams", "cssom-view", "selection-api",
  "pointerevents", "touch-events", "css-animations", "css-transitions", "fullscreen"
];

const interfaces = new Map(); // name -> record
const includes = [];          // { target, mixin }
const mixins = new Map();     // name -> members
const typedefs = new Map();   // name -> the IDL type it names

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

// The IDL type as written, e.g. "DOMString", "unsigned long", "boolean". A
// nullable or parameterized type keeps its shape ("DOMString?",
// "FrozenArray<Element>?") because HTML's reflection rules distinguish them,
// and a union is parenthesized as in IDL ("(Node or DOMString)"), so a
// generic's parameters ("record<USVString, USVString>") stay apart from it.
function idlTypeName(t) {
  if (!t) return null;
  let base;
  if (t.generic) {
    const params = Array.isArray(t.idlType) ? t.idlType : [t.idlType];
    base = t.generic + "<" + params.map(idlTypeName).join(", ") + ">";
  } else if (t.union) {
    base = "(" + t.idlType.map(idlTypeName).join(" or ") + ")";
  } else {
    base = typeof t.idlType === "object" ? idlTypeName(t.idlType) : t.idlType;
  }
  return t.nullable ? base + "?" : base;
}

// How HTML says this IDL attribute reflects, from the extended attributes the
// spec's own IDL carries (§2.6.1): [Reflect] / [ReflectURL] / [ReflectSetter]
// name the shape, [Reflect="x"] names the content attribute when it differs
// from the IDL name, and [ReflectDefault] / [ReflectRange] /
// [ReflectNonNegative] / [ReflectPositive] / [ReflectPositiveWithFallback]
// carry the numeric types' parameters. Null when the attribute does not
// reflect — which is itself worth knowing, so an implementation cannot invent
// a reflection the spec does not have.
function reflectRecord(m) {
  const ea = {};
  for (const a of m.extAttrs || []) ea[a.name] = a.rhs === undefined ? null : a.rhs;
  // HTML §2.6.1 "Using reflect via IDL extended attributes": [Reflect],
  // [ReflectSetter], [ReflectURL], [ReflectNonNegative], [ReflectPositive]
  // and [ReflectPositiveWithFallback] ALL trigger reflection, one at a time,
  // each optionally naming the content attribute — `textarea.cols` carries
  // only [ReflectPositiveWithFallback, ReflectDefault=20].
  const primary = ["ReflectURL", "ReflectSetter", "Reflect", "ReflectNonNegative",
    "ReflectPositive", "ReflectPositiveWithFallback"].find((name) => name in ea);
  if (!primary) return null;
  const shape = primary === "ReflectURL" ? "url"
    : primary === "ReflectSetter" ? "setter"
    : "plain";

  const out = { shape };
  const named = ea[primary];
  if (named && named.type === "string") out.attr = named.value.replace(/^"|"$/g, "");
  if ("ReflectDefault" in ea) out.default = literal(ea.ReflectDefault);
  if ("ReflectRange" in ea) out.range = (ea.ReflectRange.value || []).map(literal);
  if ("ReflectNonNegative" in ea) out.non_negative = true;
  if ("ReflectPositive" in ea) out.positive = true;
  if ("ReflectPositiveWithFallback" in ea) out.positive_with_fallback = true;
  return out;
}

function literal(rhs) {
  if (!rhs) return null;
  const raw = rhs.value;
  if (typeof raw !== "string") return raw;
  return rhs.type === "decimal" ? parseFloat(raw) : parseInt(raw, 10);
}

// Whether a special operation is the INDEXED one (its argument is an unsigned
// long) rather than the named one.
function hasExtAttr(m, name) {
  return (m.extAttrs || []).some((a) => a.name === name);
}

// [LegacyNullToEmptyString] is written on the TYPE — `attribute
// [LegacyNullToEmptyString] DOMString data` — and when that type is a union, as
// `innerHTML`'s is with TrustedHTML, on the DOMString member inside it.
function nullToEmptyString(m) {
  if (hasExtAttr(m, "LegacyNullToEmptyString")) return true;
  if (m.idlType && hasExtAttr(m.idlType, "LegacyNullToEmptyString")) return true;
  const inner = m.idlType && m.idlType.idlType;
  return Array.isArray(inner) && inner.some((t) => hasExtAttr(t, "LegacyNullToEmptyString"));
}

// The right-hand side of an extended attribute that has one, e.g.
// [PutForwards=value] -> "value".
function extAttrValue(m, name) {
  const found = (m.extAttrs || []).find((a) => a.name === name);
  return found && found.rhs ? String(found.rhs.value).replace(/^"|"$/g, "") : null;
}

// One overload's argument list, each argument as the IDL writes it: its type
// ("USVString", "DOMString?", "(Node or DOMString)"), whether it is optional or
// variadic, and [LegacyNullToEmptyString] when the type carries it. This is what
// a binding converts a script's values by before the operation sees them.
function argumentRecords(args) {
  return (args || []).map((a) => {
    const out = { name: a.name, type: idlTypeName(a.idlType) };
    if (a.optional) out.optional = true;
    if (a.variadic) out.variadic = true;
    if (nullToEmptyString(a)) out.null_to_empty_string = true;
    return out;
  });
}

function indexedSpecial(m) {
  const arg = m.arguments && m.arguments[0];
  return !!arg && arg.idlType && arg.idlType.idlType === "unsigned long";
}

function memberRecord(m) {
  switch (m.type) {
    case "const":
      return { kind: "const", name: m.name, value: m.value && m.value.value };
    case "attribute":
      return {
        kind: "attribute",
        name: m.name,
        static: !!m.special && m.special === "static",
        readonly: !!m.readonly,
        type: idlTypeName(m.idlType),
        reflect: reflectRecord(m),
        // The extended attributes that change how the property itself behaves,
        // as opposed to what it reflects: an own non-configurable accessor on
        // every instance, a name `with` must not bind, a null that means "",
        // the same object every read, and an assignment that forwards.
        unforgeable: hasExtAttr(m, "LegacyUnforgeable"),
        unscopable: hasExtAttr(m, "Unscopable"),
        null_to_empty_string: nullToEmptyString(m),
        same_object: hasExtAttr(m, "SameObject"),
        put_forwards: extAttrValue(m, "PutForwards"),
        // [Replaceable]: readonly, but an assignment replaces the property
        // with the assigned value instead of being ignored.
        replaceable: hasExtAttr(m, "Replaceable"),
        // `stringifier attribute USVString href`: the attribute is also what
        // the interface's toString returns.
        stringifier: m.special === "stringifier"
      };
    case "operation":
      // A getter / setter / deleter / stringifier with no name is not a member
      // a script can call, but it IS what makes an interface a legacy platform
      // object — whether its indices or its named properties are reachable, and
      // whether they can be written. Recorded as its own kind.
      if (!m.name) {
        return m.special
          ? { kind: "special", special: m.special, indexed: indexedSpecial(m) }
          : null;
      }
      return {
        kind: "operation",
        name: m.name,
        static: m.special === "static",
        // A getter / setter / deleter can be a NAMED operation too
        // (`getter Element? item(unsigned long)`), and it is still what makes
        // the interface's indices or named properties reachable.
        special: m.special && m.special !== "static" ? m.special : null,
        unforgeable: hasExtAttr(m, "LegacyUnforgeable"),
        unscopable: hasExtAttr(m, "Unscopable"),
        indexed: m.special && m.special !== "static" ? indexedSpecial(m) : null,
        // The WebIDL return type, which is what says whether an operation
        // answers with a value at all: an `undefined` one must reach a script as
        // undefined rather than as the null a host's "nothing" would cross as.
        returns: idlTypeName(m.idlType),
        required: requiredCount(m.arguments),
        total: (m.arguments || []).length,
        // Every overload's arguments, in declaration order: a name declared
        // more than once is one member with several signatures.
        signatures: [argumentRecords(m.arguments)]
      };
    // `iterable<>` / `maplike<>` / `setlike<>`: the declarations that give an
    // interface its iteration surface (@@iterator alone for a value iterator,
    // plus keys/values/entries/forEach for a pair one), rather than an
    // implementation deciding to hand out array methods.
    case "iterable":
    case "maplike":
    case "setlike":
      return { kind: m.type, pair: (m.idlType || []).length >= 2 };
    case "constructor":
      return {
        kind: "constructor", required: requiredCount(m.arguments), total: (m.arguments || []).length,
        signatures: [argumentRecords(m.arguments)]
      };
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
    if (def.type === "typedef") {
      typedefs.set(def.name, idlTypeName(def.idlType));
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
    // How a legacy platform object's NAMED properties behave: whether they are
    // enumerable, and whether they resolve before the prototype chain. Carried
    // by whichever declaration has the named getter, which may be a partial
    // (`[LegacyOverrideBuiltIns] partial interface Document`).
    rec.override_builtins = !!rec.override_builtins || !!ea.LegacyOverrideBuiltIns;
    rec.unenumerable_named_properties =
      !!rec.unenumerable_named_properties || !!ea.LegacyUnenumerableNamedProperties;
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
  const seen = new Map();
  rec.members = rec.members
    .filter((m) => {
      // A special operation has no name, so an interface's indexed and named
      // getters would collapse into one entry keyed on the empty string.
      const key = m.kind === "special"
        ? [m.kind, m.special, m.indexed].join(":")
        : m.kind + ":" + (m.name || "");
      const first = seen.get(key);
      if (first) {
        // An overload: the first declaration stands for the member, and
        // carries the later ones' arguments as further signatures.
        if (first.signatures && m.signatures) first.signatures.push(...m.signatures);
        return false;
      }
      seen.set(key, m);
      return true;
    })
    .sort((a, b) => (a.kind + (a.name || a.special || "")).localeCompare(b.kind + (b.name || b.special || "")));
  sorted[name] = rec;
}

// Which upstream the IDL came from. A clone answers for itself; a tarball — or
// the interfaces/ files fetched at a known revision, which is how the fixture is
// reproduced without a full checkout — says so through WPT_COMMIT.
let head = process.env.WPT_COMMIT || "unknown";
try {
  head = require("child_process")
    .execSync("git -C " + JSON.stringify(wpt) + " rev-parse HEAD", { encoding: "utf8" })
    .trim();
} catch (e) { /* not a git checkout: keep WPT_COMMIT, or "unknown" */ }

const out = {
  README:
    "Generated by script/build_webidl_fixture.js from a web-platform-tests " +
    "checkout's interfaces/*.idl. Do not edit by hand.",
  wpt_commit: head,
  specs: SPECS,
  // A typedef only names a type (`typedef DOMString CSSOMString`), so a
  // member written with one is converted as the type it names.
  typedefs: Object.fromEntries([...typedefs.entries()].sort(([a], [b]) => a.localeCompare(b))),
  interfaces: sorted
};

const dest = path.join(__dirname, "..", "test/fixtures/webidl/interfaces.json");
fs.mkdirSync(path.dirname(dest), { recursive: true });
fs.writeFileSync(dest, JSON.stringify(out, null, 1) + "\n");
console.log(
  "wrote " + dest + ": " + Object.keys(sorted).length + " interfaces from " + SPECS.length + " specs"
);
