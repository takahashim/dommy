// JS half of the Dommy <-> Ruby DOM bridge. Loaded once per backend and
// eval'd into the VM. Defines globalThis.__rbHost.{makeProxy, invokeCallback,
// tag, interfaceOf, seedInterfaces}.
//
// Values crossing the boundary are tagged: a bridge-able Ruby object is
// `{ __rb_handle: id }`, a JS function passed to Ruby is `{ __rb_callback: id }`.
globalThis.__rbHost = (function () {
  const HKEY = Symbol("rbHandle");
  const cache = new Map();            // handle -> WeakRef(proxy)
  // proxy -> handle, by object identity. Used to recognise our own proxies
  // WITHOUT reading a property off the candidate: probing `v[HKEY]` would fire
  // the get trap of a *foreign* proxy (e.g. a Vue/Alpine `reactive()` Proxy),
  // and because HKEY is a non-well-known symbol, Vue's reactivity tracks it as a
  // dependency. That stray symbol key then poisons the array's dep map, so a
  // later length-shrinking mutation (pop/shift/splice) does `symbol >= newLen`
  // and throws "cannot convert symbol to number". A WeakMap lookup is pure.
  const proxyHandles = new WeakMap(); // proxy -> handle (identity, trap-free)
  // handle -> proxy, STRONG. A proxy is normally cached only weakly (so it can
  // be GC'd and its Ruby handle released), but once JS code stores an expando on
  // it — framework bookkeeping like lit-html's `_$litPart$` or React's
  // `__reactFiber$…` — that state must survive as long as the node is reachable,
  // exactly as in a browser. We therefore pin the proxy here so a later access
  // (e.g. the next `getElementById` + render) returns the SAME proxy with its
  // expandos intact, rather than a fresh proxy that lost them to GC.
  const pinned = new Map();
  const callbacks = new Map();
  const callbackIds = new WeakMap();
  let nextCb = 1;

  // Whether `handle` is the GLOBAL window (globalThis.window) — distinct from an
  // iframe's contentWindow. In a browser the window IS the global object, so its
  // proxy traps treat globalThis's OWN properties as a shared namespace BOTH
  // ways: a global a script creates via `globalThis.X = …` (or a top-level `var`
  // in a UMD bundle) reads back as `window.X`, and a `window.X = …` write lands
  // on globalThis so a later bare `X` / `globalThis.X` resolves to it.
  //
  // Resolved against the LIVE globalThis.window each call (not cached): a host
  // can rebind the window (a fresh document per WPT file in a reused VM), and
  // Ruby handles are recycled once a proxy is GC'd, so a captured handle could
  // go stale and misidentify a later element proxy as the window. Two O(1)
  // lookups (own-prop read + WeakMap get); module-scoped so it isn't a fresh
  // closure on every makeHandler (one per DOM proxy).
  const isGlobalWindow = (handle) => {
    const w = globalThis.window;
    return w != null && proxyHandles.get(w) === handle;
  };

  // 2a: array-like DOM collections that cross as proxies (not as JS arrays the
  // way NodeList does) need Symbol.iterator so for-of / spread work. They expose
  // length + integer indices through the ABI, so the iterator walks those.
  const ARRAY_LIKE_COLLECTIONS = new Set([
    "HTMLCollection", "HTMLFormControlsCollection", "HTMLOptionsCollection", "NodeList",
    "RadioNodeList", "DOMTokenList", "NamedNodeMap", "DOMStringList", "FileList", "CSSRuleList",
    "StyleSheetList", "DataTransferItemList", "MediaList", "HTMLSelectElement"
  ]);
  // Legacy platform objects with a WebIDL indexed property SETTER: `obj[i] = v`
  // routes to the host (Ruby __js_set__ with the index) instead of being a
  // no-op. HTMLSelectElement / HTMLOptionsCollection add/replace/remove options.
  const INDEXED_SETTER_INTERFACES = new Set(["HTMLSelectElement", "HTMLOptionsCollection"]);
  // Map-like collections iterated as [key, value] pairs via .entries().
  const ENTRIES_ITERABLES = new Set(["URLSearchParams", "FormData", "Headers"]);

  // Array-like collections that are iterable ONLY via @@iterator (their IDL is
  // not declared `iterable<>`, so they lack keys()/values()/entries()/forEach()).
  const INDEXED_ONLY_ITERABLE = new Set(["HTMLCollection", "HTMLOptionsCollection"]);

  // WebIDL legacy platform objects with a named property getter, and whether
  // their named properties are enumerable (DOMStringMap) and writable/deletable
  // (DOMStringMap has a named setter/deleter; HTMLCollection/NamedNodeMap are
  // read-only — `coll[name] = x` / `delete coll[name]` reject in strict mode).
  const NAMED_PROP_COLLECTIONS = new Map([
    ["HTMLCollection", { enumerable: false, writable: false }],
    ["HTMLFormControlsCollection", { enumerable: false, writable: false }],
    // HTMLFormElement is [LegacyOverrideBuiltIns]: a named control shadows the
    // form's own prototype members (`form.submit`, `form.action`, `form.length`
    // return the matching control), so its named props resolve BEFORE the chain.
    ["HTMLFormElement", { enumerable: false, writable: false, overrideBuiltins: true }],
    ["HTMLOptionsCollection", { enumerable: false, writable: false }],
    ["NamedNodeMap", { enumerable: false, writable: false }],
    ["DOMStringMap", { enumerable: true, writable: true }],
    // Storage (localStorage/sessionStorage): named getter/setter/deleter, keys
    // enumerable; the named setter takes a DOMString value (ToString-coerced
    // JS-side below, like DOMStringMap).
    ["Storage", { enumerable: true, writable: true }],
  ]);

  // [LegacyNullToEmptyString] DOMString setters: null becomes "", any other
  // value is ToString-coerced JS-side before crossing into Ruby.
  const NULL_TO_EMPTY_STRING_SETTERS = new Set(["innerHTML", "outerHTML"]);

  // Form-control value-like properties exposed as accessor descriptors on the
  // interface prototype (see protoForChain) — what React's value-tracker reads
  // and wraps to detect user input on controlled components.
  const FORM_VALUE_FIELDS = {
    HTMLInputElement: ["value", "checked"],
    HTMLTextAreaElement: ["value"],
    HTMLSelectElement: ["value"],
  };

  // Read-only WebIDL attributes that need a real getter-only descriptor on the
  // prototype: normal reads still go through the proxy get trap, but reflection
  // (Object.getOwnPropertyDescriptor walking the chain, e.g. testharness's
  // assert_readonly) must find an accessor with no [[Set]].
  const READONLY_ATTRS = {
    TreeWalker: ["root", "whatToShow", "filter"],
    NodeIterator: ["root", "whatToShow", "filter", "referenceNode", "pointerBeforeReferenceNode"],
    // `template.content` is a [SameObject] readonly attribute — assert_readonly
    // walks the prototype chain expecting a getter with no setter.
    HTMLTemplateElement: ["content"],
  };

  // [LegacyUnforgeable] attributes are own accessor properties on EACH instance
  // (not the prototype), so `getOwnPropertyDescriptor(instance, name)` finds the
  // getter directly. The getter is shared per name (memoized) so its identity is
  // stable across instances — `Object.getOwnPropertyDescriptor(a, x).get ===
  // Object.getOwnPropertyDescriptor(b, x).get`, as the spec requires.
  const UNFORGEABLE_ATTRS = { Event: ["isTrusted"] };
  const unforgeableGetters = new Map();
  function unforgeableGetter(name) {
    let fn = unforgeableGetters.get(name);
    if (!fn) {
      fn = function () { return rehydrate(__rb_host_get(this[HKEY], name)); };
      unforgeableGetters.set(name, fn);
    }
    return fn;
  }

  // WebIDL [Constant]s exposed on Node (and inherited by every node interface):
  // the nodeType values plus the compareDocumentPosition bit flags.
  const NODE_CONSTANTS = {
    ELEMENT_NODE: 1, ATTRIBUTE_NODE: 2, TEXT_NODE: 3, CDATA_SECTION_NODE: 4,
    ENTITY_REFERENCE_NODE: 5, ENTITY_NODE: 6, PROCESSING_INSTRUCTION_NODE: 7,
    COMMENT_NODE: 8, DOCUMENT_NODE: 9, DOCUMENT_TYPE_NODE: 10,
    DOCUMENT_FRAGMENT_NODE: 11, NOTATION_NODE: 12,
    DOCUMENT_POSITION_DISCONNECTED: 1, DOCUMENT_POSITION_PRECEDING: 2,
    DOCUMENT_POSITION_FOLLOWING: 4, DOCUMENT_POSITION_CONTAINS: 8,
    DOCUMENT_POSITION_CONTAINED_BY: 16, DOCUMENT_POSITION_IMPLEMENTATION_SPECIFIC: 32
  };

  // WebIDL [Constant]s exposed on the Event interface object + prototype.
  const EVENT_CONSTANTS = {
    NONE: 0, CAPTURING_PHASE: 1, AT_TARGET: 2, BUBBLING_PHASE: 3
  };

  // NodeFilter whatToShow bitmasks + filter return values (TreeWalker/NodeIterator).
  const NODEFILTER_CONSTANTS = {
    FILTER_ACCEPT: 1, FILTER_REJECT: 2, FILTER_SKIP: 3,
    SHOW_ALL: 0xffffffff, SHOW_ELEMENT: 0x1, SHOW_ATTRIBUTE: 0x2, SHOW_TEXT: 0x4,
    SHOW_CDATA_SECTION: 0x8, SHOW_ENTITY_REFERENCE: 0x10, SHOW_ENTITY: 0x20,
    SHOW_PROCESSING_INSTRUCTION: 0x40, SHOW_COMMENT: 0x80, SHOW_DOCUMENT: 0x100,
    SHOW_DOCUMENT_TYPE: 0x200, SHOW_DOCUMENT_FRAGMENT: 0x400, SHOW_NOTATION: 0x800
  };

  // WebSocket ready-state [Constant]s (on the interface object + prototype, so
  // `WebSocket.OPEN` and `ws.OPEN` both resolve).
  const WEBSOCKET_CONSTANTS = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };

  // Range.compareBoundaryPoints `how` [Constant]s (interface object + prototype).
  const RANGE_CONSTANTS = { START_TO_START: 0, START_TO_END: 1, END_TO_END: 2, END_TO_START: 3 };

  // XMLHttpRequest readyState [Constant]s (on both the interface object and its
  // prototype, so `XMLHttpRequest.DONE` and `xhr.DONE` both resolve).
  const XHR_CONSTANTS = { UNSENT: 0, OPENED: 1, HEADERS_RECEIVED: 2, LOADING: 3, DONE: 4 };

  // DOMException legacy code [Constant]s — `e.INVALID_STATE_ERR` etc. equal the
  // numeric `e.code` a test compares against.
  const DOMEXCEPTION_CONSTANTS = {
    INDEX_SIZE_ERR: 1, DOMSTRING_SIZE_ERR: 2, HIERARCHY_REQUEST_ERR: 3, WRONG_DOCUMENT_ERR: 4,
    INVALID_CHARACTER_ERR: 5, NO_DATA_ALLOWED_ERR: 6, NO_MODIFICATION_ALLOWED_ERR: 7, NOT_FOUND_ERR: 8,
    NOT_SUPPORTED_ERR: 9, INUSE_ATTRIBUTE_ERR: 10, INVALID_STATE_ERR: 11, SYNTAX_ERR: 12,
    INVALID_MODIFICATION_ERR: 13, NAMESPACE_ERR: 14, INVALID_ACCESS_ERR: 15, VALIDATION_ERR: 16,
    TYPE_MISMATCH_ERR: 17, SECURITY_ERR: 18, NETWORK_ERR: 19, ABORT_ERR: 20, URL_MISMATCH_ERR: 21,
    QUOTA_EXCEEDED_ERR: 22, TIMEOUT_ERR: 23, INVALID_NODE_TYPE_ERR: 24, DATA_CLONE_ERR: 25,
  };

  // Interface name -> its [Constant]s (placed on both the interface object and
  // its prototype; instances inherit via the proxy get `prop in target` path).
  const INTERFACE_CONSTANTS = {
    Node: NODE_CONSTANTS, Event: EVENT_CONSTANTS, NodeFilter: NODEFILTER_CONSTANTS,
    WebSocket: WEBSOCKET_CONSTANTS, Range: RANGE_CONSTANTS, XMLHttpRequest: XHR_CONSTANTS,
    DOMException: DOMEXCEPTION_CONSTANTS
  };

  // B1: per-interface member names, placed on the interface prototype so
  // `'attachShadow' in Element.prototype`, `Object.getOwnPropertyDescriptor(
  // Node.prototype, 'appendChild')`, and `Element.prototype.getAttribute.call(el)`
  // work (WebIDL puts operations/attributes on the interface prototype, not the
  // instance). The seeded members are non-instance stubs that delegate to the
  // host via `this`'s handle; ordinary instance access still goes through the
  // proxy get/set traps, so this only affects prototype-level reflection. Keyed by
  // interface name; `m` = operations, `g` = readonly attributes, `p` = read-write
  // attributes. Assignment follows WebIDL, not Dommy's Ruby class layout (Node /
  // EventTarget are mixins folded into the Element class there).
  const INTERFACE_MEMBERS = {
    EventTarget: { m: ["addEventListener", "removeEventListener", "dispatchEvent"] },
    Node: {
      m: ["getRootNode", "hasChildNodes", "normalize", "cloneNode", "isEqualNode",
        "isSameNode", "compareDocumentPosition", "contains", "lookupPrefix",
        "lookupNamespaceURI", "isDefaultNamespace", "insertBefore", "appendChild",
        "replaceChild", "removeChild"],
      g: ["nodeType", "nodeName", "baseURI", "isConnected", "ownerDocument",
        "parentNode", "parentElement", "childNodes", "firstChild", "lastChild",
        "previousSibling", "nextSibling"],
      p: ["nodeValue", "textContent"]
    },
    Element: {
      m: ["hasAttributes", "getAttributeNames", "getAttribute", "getAttributeNS",
        "setAttribute", "setAttributeNS", "removeAttribute", "removeAttributeNS",
        "toggleAttribute", "hasAttribute", "hasAttributeNS", "getAttributeNode",
        "getAttributeNodeNS", "setAttributeNode", "setAttributeNodeNS",
        "removeAttributeNode", "attachShadow", "closest", "matches",
        "webkitMatchesSelector", "getElementsByTagName", "getElementsByTagNameNS",
        "getElementsByClassName", "insertAdjacentElement", "insertAdjacentText",
        "insertAdjacentHTML", "querySelector", "querySelectorAll",
        "getBoundingClientRect", "getClientRects", "scrollIntoView", "scroll",
        "scrollTo", "scrollBy", "before", "after", "replaceWith", "remove",
        "prepend", "append", "replaceChildren"],
      g: ["namespaceURI", "prefix", "localName", "tagName", "shadowRoot",
        "assignedSlot", "attributes", "classList", "firstElementChild",
        "lastElementChild", "childElementCount", "children",
        "previousElementSibling", "nextElementSibling"],
      p: ["id", "className", "slot", "innerHTML", "outerHTML"]
    },
    CharacterData: {
      m: ["substringData", "appendData", "insertData", "deleteData", "replaceData",
        "before", "after", "replaceWith", "remove"],
      g: ["length"],
      p: ["data"]
    },
    Text: { m: ["splitText"], g: ["wholeText", "assignedSlot"] },
    DocumentFragment: { m: ["getElementById", "querySelector", "querySelectorAll",
      "prepend", "append", "replaceChildren"] },
    ShadowRoot: { g: ["mode", "host", "delegatesFocus", "activeElement", "styleSheets"] },
    Document: {
      m: ["getElementById", "getElementsByTagName", "getElementsByTagNameNS",
        "getElementsByClassName", "getElementsByName", "createElement",
        "createElementNS", "createDocumentFragment", "createTextNode",
        "createCDATASection", "createComment", "createProcessingInstruction",
        "createAttribute", "createAttributeNS", "importNode", "adoptNode",
        "createEvent", "createRange", "createNodeIterator", "createTreeWalker",
        "querySelector", "querySelectorAll"],
      g: ["documentElement", "doctype", "implementation", "compatMode",
        "characterSet", "contentType", "URL", "documentURI"],
      p: ["title"]
    },
    HTMLElement: {
      m: ["click", "focus", "blur"],
      p: ["title", "lang", "dir", "hidden", "innerText"]
    }
  };
  // Precompute the shared delegating stubs (created once, reused on every proto).
  function memberMethodStub(name) {
    return function (...args) {
      return rehydrate(__rb_host_call(this[HKEY], name, dehydrateArgs(args)));
    };
  }
  function memberGetStub(name) {
    return function () { return rehydrate(__rb_host_get(this[HKEY], name)); };
  }
  function memberSetStub(name) {
    return function (v) { __rb_host_set(this[HKEY], name, dehydrateTop(v)); };
  }
  // Seed interface `name`'s WebIDL members onto its prototype (idempotent — skips
  // names already present so a subclass never shadows an inherited member).
  function seedInterfaceMembers(proto, name) {
    const members = INTERFACE_MEMBERS[name];
    if (!members) return;
    const def = (key, desc) => {
      if (!Object.prototype.hasOwnProperty.call(proto, key)) {
        Object.defineProperty(proto, key, desc);
      }
    };
    (members.m || []).forEach((mname) =>
      def(mname, { value: memberMethodStub(mname), writable: true, enumerable: true, configurable: true }));
    (members.g || []).forEach((gname) =>
      def(gname, { get: memberGetStub(gname), enumerable: true, configurable: true }));
    // NB: read-write reflected attributes (`members.p`) are deferred — a plain
    // prototype setter would bypass the proxy set trap's attribute-cache
    // invalidation and reflected-value coercion (id / innerHTML / …). They are
    // still fully functional via instance access (the proxy set trap); only their
    // prototype-level accessor descriptor is not yet seeded.
    void memberSetStub;
  }

  // 1d: custom elements. ceRegistry maps a tag name to its JS constructor;
  // constructionStack carries the element being upgraded so the interface base
  // constructor (see protoForChain) adopts it when `super()` runs; cePending
  // holds whenDefined() resolvers waiting for a name to be defined.
  const ceRegistry = new Map();
  const constructionStack = [];
  const cePending = new Map();

  // When a proxy is garbage-collected, drop the Ruby-side handle entry
  // (unless a live re-proxy for the same handle exists). Keeps the
  // registry bounded on long-lived VMs. Handles are monotonic on the
  // Ruby side, so a handle never refers to two different objects.
  const finalizers = new FinalizationRegistry((handle) => {
    const ref = cache.get(handle);
    if (!ref || ref.deref() === undefined) {
      cache.delete(handle);
      __rb_release_handle(handle);
    }
  });

  function isProxy(v) {
    return (typeof v === "object" || typeof v === "function") && v !== null && proxyHandles.has(v);
  }

  // The set of property names a prototype chain exposes via accessor setters
  // (a framework's reactive properties, e.g. Lit), computed once per prototype
  // and cached — so the set trap doesn't walk the chain on every write.
  const setterPropsCache = new WeakMap();
  function settersOf(proto) {
    let names = setterPropsCache.get(proto);
    if (names) return names;
    names = new Set();
    for (let o = proto; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
      const descs = Object.getOwnPropertyDescriptors(o);
      for (const k of Object.keys(descs)) {
        if (typeof descs[k].set === "function") names.add(k);
      }
    }
    setterPropsCache.set(proto, names);
    return names;
  }

  // Same function -> same id, so addEventListener / removeEventListener
  // round-trip to the same Ruby HostCallback (Dommy matches by identity).
  function registerCallback(fn) {
    if (callbackIds.has(fn)) return callbackIds.get(fn);
    const id = nextCb++;
    callbacks.set(id, fn);
    callbackIds.set(fn, id);
    return id;
  }

  // Called from Ruby when a host event dispatch reaches a JS-registered
  // listener. The live function (closure intact) is invoked; tagged args
  // (e.g. an Event handle) are rehydrated to proxies first.
  function invokeCallback(id, args, thisArg) {
    bumpDomEpoch(); // Ruby ran (and may have mutated the DOM) since the last JS entry
    const fn = callbacks.get(id);
    if (!fn) return undefined;
    // A null/absent thisArg keeps the historical undefined receiver; a tagged
    // value (e.g. a MutationObserver handle) sets the callback's `this`.
    const receiver = thisArg == null ? undefined : rehydrate(thisArg);
    // Catch a throwing callback and hand the thrown value back tagged, so the
    // Ruby side can decide whether to swallow (event listeners) or re-throw it
    // with identity preserved (NodeFilter, where the exception must propagate
    // out of the traversal method that ran the filter).
    try {
      return dehydrateReturn(fn.apply(receiver, rehydrate(args || [])));
    } catch (e) {
      // Preserve the thrown value's identity through the round trip, even for a
      // plain object (`throw {name:"x"}`) which dehydrate would otherwise flatten
      // to a map — assert_throws_exactly compares by identity.
      const tagged = (e !== null && (typeof e === "object" || typeof e === "function"))
        ? { __rb_js_ref: registerJsRef(e) }
        : dehydrate(e);
      return { __rb_cb_threw__: tagged };
    }
  }

  // Enqueue a host-side microtask (by id) onto the engine's native promise-job
  // queue, so a Dommy Ruby microtask (e.g. MutationObserver delivery) runs in
  // FIFO order with JS `await`/Promise reactions rather than on a separate pass.
  function scheduleMicrotask(id) {
    // The host microtask runs Ruby (MutationObserver delivery etc.), which may
    // mutate the DOM — invalidate attribute snapshots once it returns.
    Promise.resolve().then(() => { __rb_run_microtask(id); bumpDomEpoch(); });
  }

  // Replace unpaired UTF-16 surrogates with U+FFFD. Ruby strings can't hold lone
  // surrogates, so any string crossing into Ruby loses them regardless; doing the
  // scalar-value substitution here (what the spec's USVString conversion mandates,
  // e.g. for TextEncoder) yields a single U+FFFD rather than invalid bytes.
  function scrubLoneSurrogates(s) {
    let out = "";
    for (let i = 0; i < s.length; i++) {
      const c = s.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff) {
        const next = s.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) { out += s[i] + s[i + 1]; i++; }
        else out += "�";
      } else if (c >= 0xdc00 && c <= 0xdfff) {
        out += "�";
      } else {
        out += s[i];
      }
    }
    return out;
  }

  // The spec's "flatten options": addEventListener / removeEventListener observe
  // only `capture` (plus once / passive / signal for add), each read exactly once.
  // Flattening here — before dehydrate walks the bag — means an option object's
  // unrelated getters never run (e.g. a `{ get dummy() {…} }` probe stays cold).
  function flattenListenerOptions(method, options) {
    if (options == null || typeof options !== "object") return options;
    const out = { capture: !!options.capture };
    if (method === "addEventListener") {
      out.once = !!options.once;
      out.passive = !!options.passive;
      const signal = options.signal;
      if (signal !== undefined) out.signal = signal;
    }
    return out;
  }

  function dehydrate(v, seen) {
    if (typeof v === "string") return /[\ud800-\udfff]/.test(v) ? scrubLoneSurrogates(v) : v;
    if (typeof v === "function") return { __rb_callback: registerCallback(v) };
    if (isProxy(v)) return { __rb_handle: proxyHandles.get(v) };
    // A BufferSource (ArrayBuffer or any typed-array/DataView view) crosses as
    // its raw bytes, so host code gets a uniform byte buffer (TextDecoder.decode,
    // Blob, …) rather than a key→value object from Object.keys.
    if (typeof ArrayBuffer !== "undefined") {
      if (v instanceof ArrayBuffer) return { __rb_bytes: Array.from(new Uint8Array(v)) };
      if (ArrayBuffer.isView(v)) return { __rb_bytes: Array.from(new Uint8Array(v.buffer, v.byteOffset, v.byteLength)) };
    }
    // SharedArrayBuffer is a separate type (not an ArrayBuffer subclass), but a
    // BufferSource all the same — cross it as raw bytes too.
    if (typeof SharedArrayBuffer !== "undefined" && v instanceof SharedArrayBuffer) {
      return { __rb_bytes: Array.from(new Uint8Array(v)) };
    }
    if (v !== null && typeof v === "object") {
      seen = seen || new WeakSet();
      if (seen.has(v)) return undefined; // break reference cycles
      seen.add(v);
      // A nested `undefined` array element collapses to null (like JSON), so
      // arrays cross uniformly across engines (see the object branch below).
      if (Array.isArray(v)) return v.map((e) => (e === undefined ? null : dehydrate(e, seen)));
      // An "exotic" object — anything that is NOT a plain data object (Error,
      // DOMException, Map, a class instance, …) — crosses as an opaque JS-side
      // reference, so a value Ruby merely stores and hands back (an
      // AbortSignal's reason, a CustomEvent detail) round-trips with IDENTITY
      // rather than being flattened to a key→value map (which also loses an
      // Error's non-enumerable message/stack). Plain `{}` objects stay maps so
      // option bags keep behaving like Ruby Hashes.
      const proto = Object.getPrototypeOf(v);
      if (proto !== Object.prototype && proto !== null) {
        const ref = { __rb_js_ref: registerJsRef(v) };
        // An object implementing the EventListener interface (a `handleEvent`
        // method — e.g. Stimulus's action listeners) is a valid DOM event
        // listener. Tag it so the Ruby side wraps it as a listener whose
        // `handle_event` routes back here to call its handleEvent.
        if (typeof v.handleEvent === "function") ref.__rb_handle_event = true;
        if ("acceptNode" in v) ref.__rb_accept_node = true;
        return ref;
      }
      // A NodeFilter callback-interface object (`{ acceptNode }`) crosses as a
      // live reference so acceptNode is fetched fresh on each traverse (its
      // getter runs per call), invoked with `this` = the object, and a thrown
      // value propagates — none of which survives flattening to a map. Detected
      // with `in` so merely constructing the walker performs no Get.
      if ("acceptNode" in v) {
        return { __rb_js_ref: registerJsRef(v), __rb_accept_node: true };
      }
      const out = {};
      // Scrub lone surrogates in keys too (not just values): a property key is a
      // string the spec converts to a USVString, so `{ "\uD835x": … }` must reach
      // Ruby as "�x" — leaving it raw lets the gem mangle it (e.g. "U+d835").
      for (const k of Object.keys(v)) {
        const key = /[\ud800-\udfff]/.test(k) ? scrubLoneSurrogates(k) : k;
        // A NESTED `undefined` collapses to null (option-bag semantics, like
        // JSON) on every engine — done here rather than left to the backend,
        // whose undefined marshalling varies (QuickJS keeps it as a sentinel,
        // V8 gives null). Only top-level values are tagged (dehydrateTop).
        out[key] = v[k] === undefined ? null : dehydrate(v[k], seen);
      }
      return out;
    }
    return v;
  }

  // Opaque JS-value registry: lets a non-plain JS object survive a round trip
  // through Ruby with identity preserved (keyed by the value so the same object
  // reuses its id). Entries are retained for the VM's lifetime.
  const jsRefs = new Map();
  const jsRefIds = new Map();
  let jsRefSeq = 0;
  function registerJsRef(v) {
    let id = jsRefIds.get(v);
    if (id === undefined) {
      id = ++jsRefSeq;
      jsRefs.set(id, v);
      jsRefIds.set(v, id);
    }
    return id;
  }

  // Called from Ruby when a host event dispatch reaches a listener that is an
  // *object* implementing EventListener (handleEvent) rather than a function.
  // Invokes handleEvent with the object itself as `this`; the tagged event is
  // rehydrated to a proxy first.
  function invokeJsRefHandleEvent(ref, event) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const o = jsRefs.get(ref);
    if (!o || typeof o.handleEvent !== "function") return undefined;
    return dehydrateTop(o.handleEvent(rehydrate(event)));
  }

  // Invoke a NodeFilter object's acceptNode for one node. acceptNode is fetched
  // fresh (running its getter, per WHATWG callback-interface invocation) and
  // called with `this` = the filter; a thrown value (from the getter or the
  // call) is tagged so the Ruby side can re-throw it out of the traversal.
  function invokeJsRefAcceptNode(ref, node) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const o = jsRefs.get(ref);
    if (!o) return undefined;
    try {
      const fn = o.acceptNode;
      return dehydrateTop(fn.call(o, rehydrate(node)));
    } catch (e) {
      const tagged = (e !== null && (typeof e === "object" || typeof e === "function"))
        ? { __rb_js_ref: registerJsRef(e) }
        : dehydrate(e);
      return { __rb_cb_threw__: tagged };
    }
  }

  // Dehydrate a TOP-LEVEL value crossing to Ruby, tagging an explicit
  // `undefined` so it arrives as Dommy::Bridge::UNDEFINED (distinct from the
  // `nil` a JS `null` becomes). Tagging here — rather than relying on the
  // backend to marshal a bare JS `undefined` to a sentinel — keeps the protocol
  // engine-neutral: every backend gets `{__rb_undefined:true}`, whether or not
  // its value marshalling can tell `undefined` from `null` (V8/mini_racer
  // cannot). Only top-level values are tagged; `undefined` nested inside an
  // object still dehydrates to null, preserving option-bag behavior.
  function dehydrateTop(v) {
    return v === undefined ? { __rb_undefined: true } : dehydrate(v);
  }

  // Dehydrate a value a host PromiseValue settles WITH (its fulfillment value or
  // rejection reason). Unlike dehydrateTop — which flattens a plain `{}` to a
  // Ruby Hash — this keeps every JS object/function as an opaque `__rb_js_ref`,
  // so a value that merely passes JS → Ruby (the promise's slot) → JS round-trips
  // with IDENTITY. Promises/A+ settles with sentinel objects compared by `===`;
  // flattening them would make every `assert.strictEqual(value, sentinel)` fail.
  // Host proxies still cross as their handle; primitives cross by value.
  function dehydrateSettle(v) {
    if (v === undefined) return { __rb_undefined: true };
    if (v === null) return null;
    const t = typeof v;
    if (t === "object" || t === "function") {
      if (isProxy(v)) return { __rb_handle: proxyHandles.get(v) };
      return { __rb_js_ref: registerJsRef(v) };
    }
    return v;
  }

  // The Promises/A+ §2.3 "Promise Resolution Procedure" for a host PromiseValue
  // (referenced by `handle`), run engine-side because adopting a JS thenable
  // means calling its `then`. Resolving with a thenable (a native Promise, a
  // host promise proxy, or any `{ then }`) ADOPTS it — taking its eventual
  // state; resolving with a plain value fulfills. §2.3.1 self-resolution is a
  // TypeError; §2.3.3.3.3 a thenable settles at most once; §2.3.3.3.4 a throwing
  // `then` rejects.
  function resolveHostPromise(handle, value, knownThen) {
    if (isProxy(value) && proxyHandles.get(value) === handle) {
      __rb_settle_host_promise(handle, false, dehydrateSettle(new TypeError("Chaining cycle detected for promise")));
      return;
    }
    if (value !== null && (typeof value === "object" || typeof value === "function")) {
      // §2.3.3.1 — `then` is retrieved exactly ONCE. A caller that already read it
      // (dehydrateReturn, off a returned value) passes it as knownThen so a
      // one-time `then` getter isn't consumed twice. Recursive resolutions (a
      // thenable resolving with a fresh `y`) re-read, per [[Resolve]](promise, y).
      let then = knownThen;
      if (arguments.length < 3) {
        try { then = value.then; } catch (e) {
          __rb_settle_host_promise(handle, false, dehydrateSettle(e));
          return;
        }
      }
      if (typeof then === "function") {
        let called = false;
        try {
          then.call(value,
            (v) => { if (!called) { called = true; resolveHostPromise(handle, v); } },
            (r) => { if (!called) { called = true; __rb_settle_host_promise(handle, false, dehydrateSettle(r)); } });
        } catch (e) {
          if (!called) { called = true; __rb_settle_host_promise(handle, false, dehydrateSettle(e)); }
        }
        return;
      }
    }
    __rb_settle_host_promise(handle, true, dehydrateSettle(value));
  }

  // A thenable returned from a callback (notably a Promise `.then` handler) is
  // ADOPTED into a host promise so the host chain WAITS for it (Promises/A+),
  // instead of crossing as an opaque ref the host machinery resolves with
  // immediately — the microtask reorder that fires note.com's Apollo HttpLink
  // "completed without emitting" (#95). Host proxies (already host promises) and
  // plain values are unaffected. Used only for callback RETURN values, never for
  // arguments (a promise passed as an argument must not be resolved).
  function dehydrateReturn(v) {
    if (v !== null && (typeof v === "object" || typeof v === "function") && !isProxy(v)) {
      // Read `then` ONCE here (§2.3.3.1) and reuse it, so a one-time getter is not
      // consumed by a separate type-probe before resolveHostPromise reads it.
      let then;
      try { then = v.then; } catch (e) {
        // §2.3.3.2 — retrieving `then` threw: the chain rejects with the error.
        const handle = __rb_new_host_promise();
        __rb_settle_host_promise(handle, false, dehydrateSettle(e));
        return { __rb_handle: handle };
      }
      if (typeof then === "function") {
        const handle = __rb_new_host_promise();
        resolveHostPromise(handle, v, then);
        return { __rb_handle: handle };
      }
      // A non-thenable object (`then` absent or not callable, §2.3.3.4 / §2.3.4):
      // it fulfills as itself — crossed identity-preserving so `x === value`
      // holds downstream, rather than flattened to a Ruby Hash.
      return dehydrateSettle(v);
    }
    return dehydrateTop(v);
  }

  // A `{ promise, resolve, reject }` deferred backed by a host PromiseValue,
  // whose `resolve` runs the full §2.3 resolution procedure. The Promises/A+
  // conformance adapter builds on this.
  function makeHostDeferred() {
    const handle = __rb_new_host_promise();
    return {
      promise: makeProxy(handle),
      resolve: (value) => resolveHostPromise(handle, value),
      reject: (reason) => __rb_settle_host_promise(handle, false, dehydrateSettle(reason)),
    };
  }

  // Dehydrate a top-level call/constructor argument list (each arg via
  // dehydrateTop), so an explicit `undefined` argument is distinguishable from
  // null — letting WebIDL-style dispatch tell an omitted optional argument from
  // an explicit null.
  function dehydrateArgs(args) {
    return Array.prototype.map.call(args, dehydrateTop);
  }

  // A host call that raised a Dommy::DOMException comes back tagged so it can be
  // re-thrown JS-side as a real DOMException (name + legacy code, and
  // `instanceof DOMException`). Without this the quickjs gem flattens it to a
  // plain Error, breaking assert_throws_dom and the DOM's error contracts.
  function makeHostError(info) {
    const G = globalThis;
    // A deliberate JS-native error (TypeError, RangeError, …): build the real
    // constructor so `instanceof` holds. URL construction failures arrive here
    // as TypeError (per the URL Standard), not as a DOMException.
    if (info.js_native && typeof G[info.name] === "function") {
      return new G[info.name](info.message);
    }
    if (typeof G.DOMException === "function") {
      try {
        return new G.DOMException(info.message, info.name);
      } catch (_) {
        /* fall through to a plain Error */
      }
    }
    const e = new Error(info.message);
    if (info.name) e.name = info.name;
    if (info.code !== undefined && info.code !== null) e.code = info.code;
    return e;
  }

  function rehydrate(v) {
    if (Array.isArray(v)) return v.map(rehydrate);
    if (v !== null && typeof v === "object") {
      if (v.__rb_exception__) throw makeHostError(v.__rb_exception__);
      // A host-created native error crossing as a VALUE (a promise rejection
      // reason that must be `instanceof TypeError`): build the real error and
      // RETURN it (unlike __rb_exception__, which throws).
      if (v.__rb_error_value) return makeHostError(v.__rb_error_value);
      // A host method that threw an arbitrary value (throwIfAborted's reason):
      // re-throw the rehydrated value verbatim.
      if ("__rb_throw__" in v) throw rehydrate(v.__rb_throw__);
      // A void DOM op marshals as this marker so it becomes `undefined`, not the
      // `null` a bare Ruby nil would (e.g. DOMTokenList add/remove return undefined).
      if (v.__rb_undefined) return undefined;
      // A genuinely-absent property: the VALUE is `undefined` (the get trap and
      // has trap inspect the raw `__rb_absent` tag for absence semantics).
      if (v.__rb_absent) return undefined;
      // A host byte buffer (TextEncoder.encode, …) rehydrates to a Uint8Array.
      if (v.__rb_bytes) return new Uint8Array(v.__rb_bytes);
      // A host byte buffer tagged as an ArrayBuffer (Response/Blob/FileReader/
      // XHR arrayBuffer) rehydrates to a bare ArrayBuffer.
      if (v.__rb_arraybuffer) return new Uint8Array(v.__rb_arraybuffer).buffer;
      if ("__rb_handle" in v) return makeProxy(v.__rb_handle, v.__rb_if, v.__rb_ce);
      // An opaque JS-value reference round-tripping back from Ruby — restore the
      // exact original object (identity-preserving).
      if ("__rb_js_ref" in v) return jsRefs.get(v.__rb_js_ref);
      // Symmetric with dehydrate: a tagged callback restores to the live JS
      // function it was registered from (so functions nested in objects — e.g.
      // an event's detail — survive a round trip through Ruby).
      if ("__rb_callback" in v) {
        const fn = callbacks.get(v.__rb_callback);
        if (fn) return fn;
      }
      const out = {};
      for (const k of Object.keys(v)) out[k] = rehydrate(v[k]);
      return out;
    }
    return v;
  }

  // ===== wasm host bridge (handle-oriented JS access) =====
  //
  // A second embedding model, distinct from the Proxy-based one above: a wasm
  // guest (e.g. mruby-in-wasm under wasmtime-rb) drives JS through a small set
  // of imports — js_eval / js_global / js_get / js_set / js_call / js_new /
  // js_make_callback — that operate on opaque JS *handles*, not on Ruby objects
  // exposed as proxies. So the guest needs the inverse of makeProxy: any JS
  // value referenced by an integer ref it can get/set/call/new on.
  //
  // The marshalling is uniform: every non-primitive (object, function, DOM
  // proxy, exotic) crosses as `{ __rb_js_ref: id }` via the shared jsRefs table
  // (so a function can be the receiver of `new` or sit in a `.then(...)` arg
  // list — unlike dehydrate, which would flatten it to `{ __rb_callback }`).
  // Primitives cross as themselves. This pair (wasmTag/wasmUntag) is used only
  // by the wasm* entry points; the Proxy model's dehydrate/rehydrate are
  // untouched.
  function wasmTag(v) {
    if (v === undefined) return { __rb_undefined: true };
    if (v === null) return null;
    const t = typeof v;
    if (t === "string") return /[\ud800-\udfff]/.test(v) ? scrubLoneSurrogates(v) : v;
    if (t === "number" || t === "boolean") return v;
    if (t === "bigint") return Number(v);
    // object / function / symbol — keep identity behind a stable ref.
    return { __rb_js_ref: registerJsRef(v) };
  }

  function wasmUntag(v) {
    if (Array.isArray(v)) return v.map(wasmUntag);
    if (v !== null && typeof v === "object") {
      if (v.__rb_undefined) return undefined;
      if ("__rb_js_ref" in v) return jsRefs.get(v.__rb_js_ref);
      if (v.__rb_bytes) return new Uint8Array(v.__rb_bytes);
      if (v.__rb_arraybuffer) return new Uint8Array(v.__rb_arraybuffer).buffer;
      if ("__rb_handle" in v) return makeProxy(v.__rb_handle, v.__rb_if, v.__rb_ce);
      const out = {};
      for (const k of Object.keys(v)) out[k] = wasmUntag(v[k]);
      return out;
    }
    return v;
  }

  function wasmDeref(ref) {
    const v = jsRefs.get(ref);
    if (v === undefined && !jsRefs.has(ref)) {
      throw new Error("wasm bridge: stale or unknown JS ref " + ref);
    }
    return v;
  }

  // globalThis as a (tagged) ref, so the guest's `js_global` has a handle to
  // operate on.
  function wasmGlobalRef() { return wasmTag(globalThis); }

  // Indirect eval runs in global scope: `globalThis.fetch = …` and top-level
  // var/function declarations land on the global, matching a browser's
  // host-eval escape hatch (JS.eval_javascript).
  const indirectEval = eval;
  function wasmEval(src) { return wasmTag(indirectEval(src)); }

  // Execute a connected classic <script>'s body. Called from Ruby
  // (Document#script_runner) when such a script is inserted into the document,
  // so dynamically-added scripts run as a browser would. Runs inside
  // `with (window)` so bare identifiers resolve against the window object first
  // (in a browser `window` IS the global, but here it is a distinct proxy, so
  // `window.foo = …` would otherwise be invisible to a later bare `foo`). The
  // `with` is skipped for a "use strict" body (where it is illegal). The
  // completion value is voided so a trailing expression never trips the
  // unawaited-Promise guard.
  function runScript(src) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const body = String(src);
    const strict = /^\s*(["'])use strict\1/.test(body);
    if (!strict && typeof globalThis.window !== "undefined" && globalThis.window !== globalThis) {
      indirectEval("with (globalThis.window) {\n" + body + "\n}\n;void 0;");
    } else {
      indirectEval(body + "\n;void 0;");
    }
  }

  function wasmGet(ref, prop) { return wasmTag(wasmDeref(ref)[prop]); }

  function wasmSet(ref, prop, value) { wasmDeref(ref)[prop] = wasmUntag(value); }

  function wasmCall(ref, method, args) {
    const recv = wasmDeref(ref);
    const fn = recv[method];
    if (typeof fn !== "function") {
      throw new TypeError("wasm bridge: " + String(method) + " is not a function");
    }
    return wasmTag(fn.apply(recv, args.map(wasmUntag)));
  }

  // Apply a function ref directly (optionally with an explicit `this` ref).
  function wasmApply(ref, thisRef, args) {
    const fn = wasmDeref(ref);
    const thisArg = thisRef == null ? undefined : wasmDeref(thisRef);
    return wasmTag(fn.apply(thisArg, args.map(wasmUntag)));
  }

  function wasmNew(ref, args) {
    const ctor = wasmDeref(ref);
    return wasmTag(Reflect.construct(ctor, args.map(wasmUntag)));
  }

  function wasmTypeof(ref) { return typeof wasmDeref(ref); }
  function wasmToString(ref) { return String(wasmDeref(ref)); }
  function wasmStrictEqual(a, b) { return wasmDeref(a) === wasmDeref(b); }
  function wasmIsNull(ref) {
    const v = jsRefs.get(ref);
    return v === null || v === undefined;
  }
  function wasmInstanceof(ref, ctorRef) {
    const ctor = wasmDeref(ctorRef);
    return typeof ctor === "function" && wasmDeref(ref) instanceof ctor;
  }

  // Create a JS function that calls back into the wasm guest by invoke-id.
  // Returned as a ref so it can be passed to Promise.then / setTimeout / etc.
  // `globalThis.__rbWasmInvoke(id, taggedArgs)` is installed by the embedder
  // (Runtime#enable_wasm_bridge!) and routes into the guest's js_invoke_proc.
  function wasmMakeCallback(invokeId) {
    const fn = function (...args) {
      const result = globalThis.__rbWasmInvoke(invokeId, args.map(wasmTag));
      return wasmUntag(result);
    };
    return wasmTag(fn);
  }

  function wasmReleaseRef(ref) {
    const v = jsRefs.get(ref);
    if (v !== undefined || jsRefs.has(ref)) {
      jsRefs.delete(ref);
      jsRefIds.delete(v);
    }
  }

  // ===== DOM interface prototypes & constructors (1a/1b/1c) =====

  // 1c: build a host object from a bare interface constructor
  // (new Event(...) / new DOMException(...)). Ruby resolves the named
  // constructor by interface name; null means "not constructable" so we throw.
  // WebIDL dictionary members for the constructors that take an init dictionary,
  // in the order the spec reads them (inherited members first, then own, each
  // group lexicographic). "boolean" members are coerced with JS ToBoolean; "any"
  // is passed through. Only interfaces with a COMPLETE member list belong here —
  // a partial list would silently drop members.
  const CONSTRUCTOR_DICTS = {
    Event: { bubbles: "boolean", cancelable: "boolean", composed: "boolean" },
    CustomEvent: { bubbles: "boolean", cancelable: "boolean", composed: "boolean", detail: "any" },
  };

  // WebIDL argument coercion for a constructor that takes `(DOMString type,
  // optional XInit dict)`: the required `type` is ToString-coerced (so a throwing
  // `toString` propagates, and a missing argument is a TypeError), and the dict
  // is rebuilt by reading ONLY its declared members, in declaration order — so
  // unrelated getters (a stray `sweet`/`dummy`) are never invoked and a member's
  // boolean coercion follows JS, not Ruby, truthiness. Other interfaces pass
  // through untouched.
  // WebIDL `sequence<BlobPart>` conversion for the Blob/File constructors, run
  // JS-side because it is unrepresentable once flattened into Ruby: a primitive
  // string throws but a String object iterates; a plain object with @@iterator
  // is a sequence; typed arrays / ArrayBuffers become bytes. Each BlobPart is
  // reduced to what Ruby's collect_bytes understands (a byte Array, a Blob, or a
  // USVString), so Ruby never has to re-derive the type.
  function coerceBlobParts(v, name) {
    if (v === undefined) return [];
    if (v === null || typeof v !== "object") {
      throw new TypeError("Failed to construct '" + name +
        "': The provided value cannot be converted to a sequence.");
    }
    if (typeof v[Symbol.iterator] !== "function") {
      throw new TypeError("Failed to construct '" + name +
        "': The object must have a callable @@iterator property.");
    }
    const out = [];
    for (const part of v) out.push(coerceBlobPart(part));
    return out;
  }
  function coerceBlobPart(part) {
    if (part instanceof ArrayBuffer) return Array.from(new Uint8Array(part));
    if (ArrayBuffer.isView(part)) {
      return Array.from(new Uint8Array(part.buffer, part.byteOffset, part.byteLength));
    }
    if (typeof globalThis.Blob === "function" && part instanceof globalThis.Blob) return part;
    return String(part); // USVString: a throwing toString propagates
  }
  // BlobPropertyBag: reads `endings` (a required-valid EndingType enum — an
  // invalid value or a throwing getter surfaces here) and `type`.
  function coerceBlobOptions(init, name) {
    let endings = "transparent";
    let type = "";
    let lastModified;
    if (init !== undefined && init !== null) {
      if (typeof init !== "object" && typeof init !== "function") {
        throw new TypeError("Failed to construct '" + name + "': options is not an object.");
      }
      const e = init.endings; // getter may throw → propagate
      if (e !== undefined) {
        if (e !== "transparent" && e !== "native") {
          throw new TypeError("Failed to construct '" + name +
            "': The provided value '" + String(e) + "' is not a valid enum value of type EndingType.");
        }
        endings = e;
      }
      if (init.type !== undefined) {
        type = String(init.type);
        // A type with any code point outside U+0020..U+007E is discarded (→ "");
        // Ruby lowercases the rest.
        if (/[^ -~]/.test(type)) type = "";
      }
      if (init.lastModified !== undefined) lastModified = init.lastModified;
    }
    return { endings, type, lastModified };
  }

  function coerceConstructorArgs(name, args) {
    if (name === "Blob" || name === "File") {
      const isFile = name === "File";
      const parts = coerceBlobParts(args[0], name);
      const options = coerceBlobOptions(isFile ? args[2] : args[1], name);
      // "native" line endings normalize to the platform newline (LF here); only
      // string parts are affected.
      const norm = options.endings === "native"
        ? parts.map((p) => (typeof p === "string" ? p.replace(/\r\n|\r|\n/g, "\n") : p))
        : parts;
      if (isFile) {
        if (args.length < 2) {
          throw new TypeError("Failed to construct 'File': 2 arguments required, but only " +
            args.length + " present.");
        }
        const opts = { type: options.type };
        if (options.lastModified !== undefined) opts.lastModified = options.lastModified;
        return [norm, String(args[1]), opts];
      }
      return [norm, { type: options.type }];
    }
    if (name === "URLSearchParams") {
      // Per spec a non-string iterable init (another URLSearchParams, a Map, an
      // object with a custom @@iterator) is a *sequence* of pairs — materialize
      // it through its live iterator HERE so the iterator runs JS-side; Ruby only
      // ever sees plain pair arrays. Plain records (no @@iterator) and strings
      // fall through unchanged to the record / string paths.
      const init = args[0];
      if (init !== null && typeof init === "object" && typeof init[Symbol.iterator] === "function") {
        return [Array.from(init, (pair) => Array.from(pair))];
      }
      return args;
    }
    const members = CONSTRUCTOR_DICTS[name];
    if (!members) return args;
    if (args.length < 1) {
      throw new TypeError("Failed to construct '" + name + "': 1 argument required, but only 0 present.");
    }
    const type = String(args[0]);
    const init = args[1];
    const dict = {};
    if (init !== undefined && init !== null) {
      for (const member in members) {
        const value = init[member];
        if (value === undefined) continue;
        dict[member] = members[member] === "boolean" ? !!value : value;
      }
    }
    return [type, dict];
  }

  function constructInterface(name, args) {
    const r = rehydrate(__rb_construct(name, dehydrateArgs(coerceConstructorArgs(name, args))));
    if (r == null) throw new TypeError("Illegal constructor");
    return r;
  }

  // 1b: lazily build a JS prototype chain + constructor per DOM interface,
  // mirroring the chain Ruby reports (most-derived first). Cached by name so the
  // shared tail (…Element→Node→EventTarget) is built once and every node links
  // into the same prototypes — making `instanceof` and Object.prototype.toString
  // (via Symbol.toStringTag) work. Constructable interfaces (Event, DOMException,
  // …) build via Ruby; the rest throw Illegal constructor (HTMLElement until 1d).
  const protos = new Map();
  // 2d: method name sets are per-interface (class), so cache them by interface
  // name and reuse across every proxy of that interface instead of rebuilding.
  const methodsByInterface = new Map();
  // Full per-interface descriptor (name + prototype chain + method names) keyed
  // by interface name. A handle that crosses tagged with its interface (see the
  // marshaller) reuses this instead of a `__rb_host_describe` round trip; the
  // describe path (untagged / first sighting of an interface) fills it.
  const descByInterface = new Map();
  function protoForChain(chain, i) {
    const name = chain[i];
    const cached = protos.get(name);
    if (cached) return cached;
    const parent = (i + 1 < chain.length) ? protoForChain(chain, i + 1) : Object.prototype;
    const proto = Object.create(parent);
    Object.defineProperty(proto, Symbol.toStringTag, { value: name, configurable: true });
    // Only node/element constructors adopt an element being upgraded. Otherwise
    // a non-element `new` (e.g. `new IntersectionObserver()` inside a custom
    // element's constructor) would greedily adopt the queued element off the
    // shared construction stack and hijack its prototype.
    const consultsStack = chain.includes("Node");
    const ctor = function (...args) {
      const nt = new.target;
      if (nt === undefined) throw new TypeError(name + " requires 'new'");
      // 1d: custom element upgrade — when a construction is queued, `super()`
      // adopts the element being upgraded (its proxy) and stamps it with the
      // derived class's prototype, rather than minting a new backing object.
      if (consultsStack && constructionStack.length > 0) {
        const el = constructionStack[constructionStack.length - 1];
        Object.setPrototypeOf(el, nt.prototype);
        return el;
      }
      // 1d: direct `new MyElement()` (no queued upgrade) — the HTMLElement
      // constructor algorithm. When new.target is a registered custom element
      // constructor, mint its backing Dommy element now (autonomous custom
      // element construction), adopt the proxy WITHOUT re-running this ctor, and
      // stamp it with the derived prototype. An unregistered new.target (bare
      // `new HTMLElement()` / an unregistered subclass) falls through to Ruby,
      // which returns null → "Illegal constructor", per spec.
      // Autonomous custom element construction runs only in the HTMLElement base
      // ctor: an element's super() chain reaches here iff it `extends HTMLElement`.
      // A class that extends a built-in interface instead (HTMLParagraphElement,
      // HTMLButtonElement, …) reaches THAT ctor's name, misses this branch, and
      // falls through to Ruby → TypeError (Dommy has no customized built-ins).
      // `nt !== ctor` additionally rejects `new HTMLElement()` itself (even when
      // HTMLElement was passed to customElements.define): only a user subclass as
      // new.target may construct.
      if (name === "HTMLElement" && nt !== ctor) {
        const ceName = ceNameForCtor(nt);
        if (ceName !== undefined) {
          const wire = __rb_create_custom_element(ceName);
          if (wire && typeof wire === "object" && "__rb_handle" in wire) {
            const p = makeProxy(wire.__rb_handle, wire.__rb_if, wire.__rb_ce, true);
            Object.setPrototypeOf(p, nt.prototype);
            return p;
          }
        }
      }
      return constructInterface(name, args);
    };
    Object.defineProperty(ctor, "name", { value: name, configurable: true });
    ctor.prototype = proto;
    Object.defineProperty(proto, "constructor", { value: ctor, configurable: true, writable: true });
    // WebIDL [Constant]s live on both the interface object and its prototype
    // (so `Node.ELEMENT_NODE`, `el.ELEMENT_NODE`, `Event.CAPTURING_PHASE`, …
    // all === the numeric value). Instances reach the prototype copy via the
    // proxy get trap's `prop in target` fallback.
    const constants = INTERFACE_CONSTANTS[name];
    if (constants) {
      for (const [k, val] of Object.entries(constants)) {
        const desc = { value: val, enumerable: true, writable: false, configurable: false };
        Object.defineProperty(proto, k, desc);
        Object.defineProperty(ctor, k, desc);
      }
    }
    seedInterfaceMembers(proto, name);
    if (ARRAY_LIKE_COLLECTIONS.has(name)) {
      // WebIDL: a value-iterator interface (indexed getter + `iterable<>`) gets
      // keys()/values()/entries()/forEach()/@@iterator whose values ARE the
      // %Array.prototype% functions — so `list.values === Array.prototype.values`.
      // They operate on the proxy via its live length + indexed getter, and each
      // returns a real Array Iterator (so `list.keys() instanceof Array` is false).
      const A = Array.prototype;
      const define = (key, fn) => Object.defineProperty(proto, key, { value: fn, configurable: true, writable: true });
      define(Symbol.iterator, A[Symbol.iterator]);
      // HTMLCollection is iterable only via @@iterator (its IDL is NOT declared
      // `iterable<>`); the keys()/values()/entries()/forEach() pair methods are
      // exclusive to interfaces that ARE (NodeList, DOMTokenList, …).
      if (!INDEXED_ONLY_ITERABLE.has(name)) {
        define("values", A.values);
        define("keys", A.keys);
        define("entries", A.entries);
        define("forEach", A.forEach);
      }
    } else if (ENTRIES_ITERABLES.has(name)) {
      // A LIVE iterator: re-read entries() at each step (indexed by a running
      // cursor) so a mutation mid-loop is observed — e.g. URLSearchParams
      // `for (const e of params) { params.delete(...) }` must see the new state.
      // entries()/keys()/values()/@@iterator each return such an iterator (the
      // WebIDL maplike contract) — a `for…of` and a direct `.entries().next()`
      // both work — rather than a plain Array. keys/values project the pair.
      // Read the raw [name, value] pairs straight from the host — NOT via
      // `self.entries()`, which is now this same iterator-returning override.
      const rawEntries = (self) => {
        const r = rehydrate(__rb_host_call(self[HKEY], "entries", dehydrateArgs([])));
        return Array.isArray(r) ? r : [];
      };
      const liveIterator = (self, project) => {
        let i = 0;
        const it = {
          next() {
            const entries = rawEntries(self);
            if (i >= entries.length) return { value: undefined, done: true };
            return { value: project(entries[i++]), done: false };
          },
        };
        it[Symbol.iterator] = function () { return this; };
        return it;
      };
      const defineIter = (key, project) => Object.defineProperty(proto, key, {
        value: function () { return liveIterator(this, project); },
        configurable: true, writable: true,
      });
      defineIter(Symbol.iterator, (e) => e);
      defineIter("entries", (e) => e);
      defineIter("keys", (e) => e[0]);
      defineIter("values", (e) => e[1]);
    }
    if (name === "TextEncoder") {
      // encodeInto mutates the destination Uint8Array in place, so it must run
      // JS-side (a host round trip would only see a copy). Encodes scalar values
      // to UTF-8, stops before a code point that wouldn't fit, and returns
      // {read (source UTF-16 units), written (bytes)}.
      Object.defineProperty(proto, "encodeInto", {
        value: function (source, destination) {
          if (!(destination instanceof Uint8Array)) {
            throw new TypeError("encodeInto's destination must be a Uint8Array");
          }
          source = String(source);
          const cap = destination.length;
          let read = 0, written = 0;
          for (let i = 0; i < source.length;) {
            let cp = source.codePointAt(i);
            let units = cp > 0xffff ? 2 : 1;
            if (cp >= 0xd800 && cp <= 0xdfff) { cp = 0xfffd; units = 1; } // lone surrogate
            const need = cp <= 0x7f ? 1 : cp <= 0x7ff ? 2 : cp <= 0xffff ? 3 : 4;
            if (written + need > cap) break;
            if (need === 1) {
              destination[written++] = cp;
            } else if (need === 2) {
              destination[written++] = 0xc0 | (cp >> 6);
              destination[written++] = 0x80 | (cp & 0x3f);
            } else if (need === 3) {
              destination[written++] = 0xe0 | (cp >> 12);
              destination[written++] = 0x80 | ((cp >> 6) & 0x3f);
              destination[written++] = 0x80 | (cp & 0x3f);
            } else {
              destination[written++] = 0xf0 | (cp >> 18);
              destination[written++] = 0x80 | ((cp >> 12) & 0x3f);
              destination[written++] = 0x80 | ((cp >> 6) & 0x3f);
              destination[written++] = 0x80 | (cp & 0x3f);
            }
            read += units;
            i += units;
          }
          return { read, written };
        },
        configurable: true, writable: true,
      });
    }
    if (name === "ReadableStream") {
      // WHATWG: a ReadableStream is async-iterable — `for await (const chunk of
      // stream)` acquires a reader and yields each chunk. Real browsers expose
      // this; code that streams a fetch body (e.g. Apollo Client's multipart /
      // incremental-delivery reader) depends on it, and without it such a read
      // sees an immediately-"done" iterator and produces nothing. Backed by the
      // stream's own getReader()/read().
      Object.defineProperty(proto, Symbol.asyncIterator, {
        value: function () {
          const reader = this.getReader();
          return {
            async next() {
              const { value, done } = await reader.read();
              if (done) { reader.releaseLock(); return { value: undefined, done: true }; }
              return { value, done: false };
            },
            async return(v) { reader.releaseLock(); return { value: v, done: true }; },
            [Symbol.asyncIterator]() { return this; },
          };
        },
        configurable: true, writable: true,
      });
    }
    // Form-control value-like properties as real accessor descriptors on the
    // prototype, routing to the host. React's input value-tracker reads the
    // descriptor off `node.constructor.prototype` and wraps its get/set to
    // detect user edits; with no prototype accessor it bails and controlled
    // inputs never fire onChange. Normal `el.value` reads still go straight
    // through the proxy get trap (host_get); these accessors are what
    // getOwnPropertyDescriptor(prototype, …) and React's wrapper call.
    const valueFields = FORM_VALUE_FIELDS[name];
    if (valueFields) {
      for (const field of valueFields) {
        Object.defineProperty(proto, field, {
          configurable: true,
          enumerable: true,
          get() { return rehydrate(__rb_host_get(this[HKEY], field)); },
          set(v) {
            const r = __rb_host_set(this[HKEY], field, dehydrateTop(v));
            // Propagate a throwing host setter (e.g. a file input's value=)
            // rather than swallowing it, as the general set trap does.
            if (r && typeof r === "object" && r.__rb_exception__) throw makeHostError(r.__rb_exception__);
          },
        });
      }
    }
    const readonlyAttrs = READONLY_ATTRS[name];
    if (readonlyAttrs) {
      for (const field of readonlyAttrs) {
        Object.defineProperty(proto, field, {
          configurable: true,
          enumerable: true,
          get() { return rehydrate(__rb_host_get(this[HKEY], field)); },
        });
      }
    }
    if (!(name in globalThis)) globalThis[name] = ctor;
    protos.set(name, proto);
    return proto;
  }

  // Legacy named constructors (HTML `[LegacyFactoryFunction]`): a global factory
  // function whose `.prototype` IS the target interface's prototype, so
  // `new Image() instanceof HTMLImageElement` holds and `(new Image).constructor`
  // is HTMLImageElement (the prototype's own `constructor`). Construction routes
  // to Ruby (which builds the actual <img>/<audio>/<option> element).
  const NAMED_CONSTRUCTORS = { Image: "HTMLImageElement", Audio: "HTMLAudioElement", Option: "HTMLOptionElement" };

  function exposeNamedConstructors() {
    for (const alias in NAMED_CONSTRUCTORS) {
      if (alias in globalThis) continue;
      const proto = protos.get(NAMED_CONSTRUCTORS[alias]);
      if (!proto) continue;
      const ctor = function (...args) {
        if (new.target === undefined) throw new TypeError(alias + " requires 'new'");
        return constructInterface(alias, args);
      };
      Object.defineProperty(ctor, "name", { value: alias, configurable: true });
      ctor.prototype = proto; // share the interface prototype -> instanceof works
      globalThis[alias] = ctor;
    }
  }

  // Eagerly build the base interfaces (chains supplied by Ruby, the single
  // source of hierarchy knowledge) so `instanceof Node` / `typeof HTMLElement`
  // resolve before an instance of that exact type has crossed.
  function seedInterfaces(chains) {
    chains.forEach((c) => protoForChain(c, 0));
    exposeNamedConstructors();
  }

  // 1c: expose an interface constructor's static/class methods (URL.createObjectURL,
  // URL.parse, …) on the seeded global, delegating to the window's constructor.
  // Called once the window is bound (statics live on the window's constructors).
  function attachStatics() {
    for (const name of protos.keys()) {
      const ctor = globalThis[name];
      if (typeof ctor !== "function") continue;
      for (const m of __rb_static_names(name)) {
        if (m in ctor) continue;
        ctor[m] = (...args) => rehydrate(__rb_static_call(name, m, dehydrateArgs(args)));
      }
    }
  }

  // Expose the interface constructors as own properties of the `window` proxy
  // so `window.Node` / `document.defaultView.DOMException` / … resolve to the
  // same constructor functions as the bare globals. In a browser window IS the
  // global object; here it's a separate host proxy whose host get returns null
  // for these, which broke e.g. assert_throws_dom(type, doc.defaultView.DOMException, …)
  // (it read `.name` off null). Defining them on the proxy target means the get
  // trap's own-property fast path returns the real function with no round trip.
  function exposeConstructorsOnWindow(target) {
    // Defaults to the top window, but a secondary window (an iframe's
    // contentWindow) can be passed so `subWin.Element` / `subWin.DOMException`
    // resolve to the same seeded constructors — needed for cross-window
    // `instanceof` and `doc.defaultView.X` in iframe documents.
    const w = target || globalThis.window;
    if (!w) return;
    const names = [...protos.keys()];
    if (typeof globalThis.DOMException === "function") names.push("DOMException");
    // Mirror the JS built-in constructors too, so an iframe's contentWindow
    // resolves `defaultView.TypeError` / `defaultView.Array` like a real window
    // (WPT reaches for `(root.ownerDocument).defaultView.TypeError`).
    names.push(
      "Object", "Array", "Function", "String", "Boolean", "Number", "BigInt",
      "Symbol", "Date", "RegExp", "Promise", "Map", "Set", "WeakMap", "WeakSet",
      "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
      "Proxy", "Reflect", "JSON", "Math"
    );
    const interfaceNames = new Set(protos.keys());
    // Legacy named constructors are seeded JS functions too; the window
    // otherwise resolves them to the host-backed Constructor proxy (a
    // non-constructable "object"), so replace those the same way as interfaces.
    for (const alias in NAMED_CONSTRUCTORS) { names.push(alias); interfaceNames.add(alias); }
    for (const name of names) {
      const ctor = globalThis[name];
      if (typeof ctor !== "function") continue;
      try {
        const current = w[name];
        // Fill in names the window doesn't resolve at all; AND replace a
        // host-backed interface object (e.g. window.Event / window.MutationObserver
        // crossing as a non-constructable Dommy proxy) with the constructable
        // seeded constructor, so `new document.defaultView.MutationObserver(cb)`
        // works — in a real window, window.X IS the constructor function X.
        if (current == null || (typeof current !== "function" && interfaceNames.has(name))) {
          Object.defineProperty(w, name, { value: ctor, configurable: true, writable: true });
        }
      } catch (e) { /* non-configurable / frozen — leave as-is */ }
    }
    // JS builtins must BE the engine's native globals on the window too
    // (`window.Object === Object`, `window.console === console`, `x in
    // window.console`), like a real browser. The host's __js_get__ returns
    // sentinels for some of these (console / Object / Array / JSON) that
    // otherwise cross as the WRONG type — a string — so `window.console.foo`
    // and `x in window.console` throw ("invalid 'in' operand"); note.com's
    // console wrapper hit this. The loop above misses them (non-function
    // builtins are skipped; sentinel-stringed ones aren't interfaces). Promise
    // also MUST be the native one so feature detection (core-js et al.) doesn't
    // swap in a polyfill whose microtasks the host can't flush. Force them all.
    for (const name of JS_GLOBALS) {
      if (!(name in globalThis)) continue;
      try {
        Object.defineProperty(w, name, { value: globalThis[name], configurable: true, writable: true });
      } catch (e) { /* non-configurable / frozen — leave as-is */ }
    }
  }

  // The engine's native globals that `window.X` must mirror exactly.
  const JS_GLOBALS = [
    "Object", "Array", "Function", "String", "Boolean", "Number", "BigInt",
    "Symbol", "Date", "RegExp", "Promise", "Map", "Set", "WeakMap", "WeakSet",
    "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
    "Proxy", "Reflect", "JSON", "Math", "console",
  ];

  // ===== Host object proxy =====

  // The proxy traps route each access to one of the bridge's layers. The order
  // is deliberate — changing it breaks subtle cases, so it's spelled out here:
  //
  //   get(prop):
  //     1. HKEY symbol             -> the Ruby handle (identity tag)
  //     2. any other symbol        -> target/prototype (Symbol.toStringTag/iterator)
  //     3. own property on target  -> a JS-side expando (object identity intact)
  //     4. ABI method name         -> a per-proxy memoized fn (__rb_host_call)
  //     5. ABI property (non-null) -> the __rb_host_get value
  //     6. prototype member        -> constructor / connectedCallback / etc.
  //
  //   set(prop, value):
  //     1. symbol                  -> store on the target
  //     2. prototype setter        -> run it (framework reactive props, e.g. Lit)
  //     3. Dommy handled it        -> a DOM property write
  //     4. otherwise               -> a JS-side expando on the target
  // An array index property name: "0", "1", … (canonical, no leading zeros).
  function isArrayIndex(prop) {
    return typeof prop === "string" && /^(0|[1-9][0-9]*)$/.test(prop);
  }

  // Node properties that are constant for the node's lifetime (DOM spec:
  // readonly, fixed at creation), so a Node-chain proxy may answer them from a
  // per-proxy cache instead of a bridge round trip. These are the hottest
  // reads in framework scans (Turbo's PageSnapshot classifies every element
  // by localName; Stimulus checks nodeType per mutation record), so caching
  // them removes a large share of `__rb_host_get` traffic with no
  // invalidation concern.
  const CONST_NODE_PROPS = new Set(["nodeType", "nodeName", "localName", "tagName"]);

  // IDL reflected string attributes that return the content attribute value
  // verbatim ("" when absent): the property name -> its content attribute. These
  // are answerable from the element's attribute snapshot (the same cache
  // getAttribute uses), so a framework's per-element id/className scan (Turbo's
  // PageSnapshot, Stimulus's targets) needs no bridge crossing. Only pure
  // reflections whose Ruby getter is exactly `node[attr].to_s` are listed —
  // properties with coercion/defaults (dir, tabIndex, booleans) are NOT.
  const REFLECTED_STRING_ATTRS = new Map([
    ["id", "id"], ["className", "class"], ["slot", "slot"],
  ]);

  // Node properties that are stable WITHIN a DOM epoch (they change only via a
  // DOM mutation, which bumps the epoch) but are not lifetime-constant like
  // CONST_NODE_PROPS. Tree-walk loops read these repeatedly, and each read is a
  // full crossing + result-proxy rehydrate (measured: nextSibling ~10us,
  // parentNode ~2.5us). Caching them per-epoch collapses a walk's repeated reads
  // to one crossing each. All return a node/null/number/string — no value here
  // needs the get-trap fallback paths (global-window / collection).
  const STABLE_EPOCH_NODE_PROPS = new Set([
    "parentNode", "parentElement", "ownerDocument",
    "firstChild", "lastChild", "nextSibling", "previousSibling",
    "firstElementChild", "lastElementChild",
    "nextElementSibling", "previousElementSibling",
    "childElementCount", "textContent",
    // Live collections: the NodeList/HTMLCollection object is stable (its
    // contents track mutations, but the read returns the same live proxy), so
    // caching the proxy per-epoch avoids re-crossing to fetch it on every
    // `.childNodes`/`.children` access in a walk.
    "childNodes", "children",
  ]);

  // ===== DOM epoch (attribute-cache invalidation) =====
  //
  // Element proxies cache their full attribute map (fetched in ONE crossing
  // via __rb_host_attrs) and answer getAttribute/hasAttribute locally while
  // the DOM is provably unchanged. "Provably unchanged" is tracked by a single
  // counter: any event that could mutate the DOM bumps it, and a bumped epoch
  // lazily invalidates every proxy's snapshot. Bump sites:
  //
  //   * a proxy method call NOT known to be read-only (setAttribute,
  //     appendChild, classList.add via the DOMTokenList proxy, …) — bumped
  //     before AND after, so a reentrant callback during the Ruby call
  //     (attributeChangedCallback) never reads a stale snapshot
  //   * a proxy property write / named delete (__rb_host_set / __rb_host_delete)
  //   * every Ruby -> JS entry (invokeCallback / invokeLifecycle /
  //     invokeJsRefHandleEvent / invokeJsRefAcceptNode / runScript, and after
  //     a host microtask ran Ruby) — between JS runs, Ruby test code may have
  //     mutated the DOM directly
  //
  // Reads can only happen while JS executes, and JS executes only between
  // those bump sites, so a snapshot taken at epoch N is valid for every read
  // at epoch N. The cost of over-bumping is a refetch (one crossing), never a
  // stale answer.
  let domEpoch = 0;
  function bumpDomEpoch() { domEpoch += 1; }

  // Proxy methods that never mutate the DOM (pure queries / listener
  // registration), so calling them does NOT bump the epoch. Anything not
  // listed is treated as potentially mutating — correctness over cache hits.
  const NON_MUTATING_METHODS = new Set([
    "getAttribute", "getAttributeNS", "getAttributeNames", "getAttributeNode",
    "hasAttribute", "hasAttributeNS", "hasAttributes",
    "matches", "closest", "contains", "isEqualNode", "isSameNode",
    "querySelector", "querySelectorAll",
    "getElementsByTagName", "getElementsByTagNameNS", "getElementsByClassName",
    "getElementById", "getRootNode", "compareDocumentPosition",
    "getBoundingClientRect", "getClientRects", "checkVisibility",
    "item", "namedItem", "getPropertyValue", "getPropertyPriority",
    "addEventListener", "removeEventListener",
    "observe", "unobserve", "disconnect", "takeRecords",
  ]);

  function makeHandler(handle, methods, methodCache, arrayLike, named, nodeChain, indexedSetter) {
    // Cached constant-prop values (CONST_NODE_PROPS) for a Node proxy; null
    // for non-Node interfaces so the cache check stays out of their get path.
    const constCache = nodeChain ? new Map() : null;
    // Reflected-attribute map, only for Node proxies (elements have the
    // snapshot; other node kinds return null from attrsSnapshot and fall back).
    const reflectAttrs = nodeChain ? REFLECTED_STRING_ATTRS : null;
    // Per-epoch cache of stable node props (STABLE_EPOCH_NODE_PROPS). Rebuilt
    // whenever the epoch moves; only used for Node proxies.
    let epochProps = null;
    let epochPropsEpoch = -1;
    // The element's attribute snapshot for the current DOM epoch:
    //   undefined -> not fetched this epoch;  null -> permanently uncacheable
    //   (not an element / case-sensitive foreign-namespace lookups);
    //   object    -> {name: value}, valid while attrsEpoch === domEpoch.
    let attrsCache;
    let attrsEpoch = -1;
    const attrsSnapshot = () => {
      if (attrsCache === null) return null;
      if (attrsCache === undefined || attrsEpoch !== domEpoch) {
        // A host that registered only part of the ABI (a bare-bones harness)
        // may lack __rb_host_attrs — then this proxy is permanently uncached.
        const snap = (typeof globalThis.__rb_host_attrs === "function")
          ? __rb_host_attrs(handle) : null;
        attrsCache = (snap !== null && typeof snap === "object") ? snap : null;
        attrsEpoch = domEpoch;
      }
      return attrsCache;
    };
    // A cached-attribute read: answers from the snapshot when one is
    // available, else falls back to a normal bridge call. Lookup lowercases
    // the argument — snapshots exist only for elements whose Ruby-side lookup
    // is case-insensitive, so this matches get_attribute exactly. "__proto__"
    // is excluded (a snapshot object can't represent it as a data property).
    const cachedAttrRead = (method, name) => {
      let attrs = null;
      let key;
      if (typeof name === "string") {
        key = name.toLowerCase();
        if (key !== "__proto__") attrs = attrsSnapshot();
      }
      if (attrs === null) return rehydrate(__rb_host_call(handle, method, dehydrateArgs([name])));
      if (method === "hasAttribute") return Object.hasOwn(attrs, key);
      return Object.hasOwn(attrs, key) ? attrs[key] : null;
    };
    // The live length of an array-like collection (NodeList/HTMLCollection/…),
    // so indexed own-property reflection (hasOwnProperty / Object.keys / spread)
    // tracks the current children. 0 for non-collections.
    // Epoch-cached: a collection's length changes only via a DOM mutation
    // (which bumps the epoch), so within an epoch it is fetched once and reused
    // for every `.length` read and index-range check.
    let liveLenCache = 0;
    let liveLenEpoch = -1;
    const liveLength = () => {
      if (!arrayLike) return 0;
      if (liveLenEpoch === domEpoch) return liveLenCache;
      const n = rehydrate(__rb_host_get(handle, "length"));
      liveLenCache = typeof n === "number" && n >= 0 ? n : 0;
      liveLenEpoch = domEpoch;
      return liveLenCache;
    };
    // The live WebIDL "supported property names" (named getter keys), re-queried
    // each call so it tracks DOM mutations; [] when there is no named getter.
    const namedKeys = () => {
      if (!named) return [];
      const r = rehydrate(__rb_named_props(handle));
      return Array.isArray(r) ? r : [];
    };
    const isIndexInRange = (prop) => arrayLike && isArrayIndex(prop) && Number(prop) < liveLength();
    const isNamedKey = (prop) => named && typeof prop === "string" && namedKeys().indexOf(prop) !== -1;
    // WebIDL named-property visibility: a named property is EXPOSED (reachable
    // via property access / enumeration) only when it is not shadowed by an own
    // expando or — absent [LegacyOverrideBuiltIns], which none of our named
    // collections declare — a property anywhere on the prototype chain. So
    // `Storage.prototype.foo = x` hides the stored "foo" from `storage.foo`
    // while `storage.getItem("foo")` still returns it.
    const namedShadowedByProto = (t, prop) => {
      // [LegacyOverrideBuiltIns]: named props are NOT shadowed by the prototype
      // chain (only by an own expando, checked separately before this).
      if (named && named.overrideBuiltins) return false;
      const proto = Object.getPrototypeOf(t);
      return proto != null && (prop in proto);
    };
    return {
      get(t, prop, receiver) {
        if (prop === HKEY) return handle;
        if (typeof prop === "symbol") return Reflect.get(t, prop, receiver);
        if (Object.hasOwn(t, prop)) return Reflect.get(t, prop, receiver);
        // [LegacyOverrideBuiltIns] (HTMLFormElement): a named control shadows the
        // prototype's methods AND accessors, so resolve it before either. An own
        // expando (checked above) still wins.
        if (named && named.overrideBuiltins && typeof prop === "string" && isNamedKey(prop)) {
          return rehydrate(__rb_host_get(handle, prop));
        }
        if (methods.has(prop)) {
          let fn = methodCache.get(prop);
          if (!fn) {
            if (prop === "addEventListener" || prop === "removeEventListener") {
              fn = (...args) => {
                if (args.length >= 3) args[2] = flattenListenerOptions(prop, args[2]);
                return rehydrate(__rb_host_call(handle, prop, dehydrateArgs(args)));
              };
            } else if (nodeChain && (prop === "getAttribute" || prop === "hasAttribute")) {
              fn = (name) => cachedAttrRead(prop, name);
            } else if (NON_MUTATING_METHODS.has(prop)) {
              fn = (...args) => rehydrate(__rb_host_call(handle, prop, dehydrateArgs(args)));
            } else {
              // Potentially mutating: bump the epoch before (a reentrant
              // callback during the call must not read stale snapshots) and
              // after (the call's own mutations invalidate later reads).
              fn = (...args) => {
                bumpDomEpoch();
                try {
                  return rehydrate(__rb_host_call(handle, prop, dehydrateArgs(args)));
                } finally {
                  bumpDomEpoch();
                }
              };
            }
            methodCache.set(prop, fn);
          }
          return fn;
        }
        // A named-collection key shadowed by the prototype chain resolves to the
        // prototype value, not the stored named property (no LegacyOverrideBuiltIns).
        if (named && !arrayLike && typeof prop === "string" && namedShadowedByProto(t, prop)) {
          return Reflect.get(t, prop, receiver);
        }
        if (constCache !== null && constCache.has(prop)) return constCache.get(prop);
        // Reflected string attribute (id/className/slot): answer from the
        // element's attribute snapshot, no crossing. Only when a snapshot is
        // available (HTML elements) — non-elements / foreign-namespace get null
        // and fall through to the host, preserving e.g. `document.title`.
        if (reflectAttrs !== null && typeof prop === "string") {
          const attrKey = reflectAttrs.get(prop);
          if (attrKey !== undefined) {
            const attrs = attrsSnapshot();
            if (attrs !== null) return Object.hasOwn(attrs, attrKey) ? attrs[attrKey] : "";
          }
        }
        // Stable-within-epoch node prop (parentNode/nextSibling/textContent/…):
        // answer from a per-epoch cache so a tree-walk's repeated reads cross
        // once, not once per iteration. The epoch bumps on any mutation or
        // Ruby -> JS entry, so a cached value is never stale.
        if (nodeChain && STABLE_EPOCH_NODE_PROPS.has(prop)) {
          if (epochPropsEpoch !== domEpoch) { epochProps = new Map(); epochPropsEpoch = domEpoch; }
          if (epochProps.has(prop)) return epochProps.get(prop);
          const val = rehydrate(__rb_host_get(handle, prop));
          epochProps.set(prop, val);
          return val;
        }
        // A collection's `.length` is the epoch-cached live count — the same
        // value index-range checks use, fetched once per epoch not per read.
        if (arrayLike && prop === "length") return liveLength();
        const raw = __rb_host_get(handle, prop);
        // The host signals a genuinely-absent property with the ABSENT tag (value
        // is `undefined`); a present-but-null property is bare nil (→ JS null).
        // "Host owns nothing here" = absent OR (legacy) null, and only that drives
        // the global / collection fallbacks below — NOT a real null value.
        const isAbsent = raw !== null && typeof raw === "object" && raw.__rb_absent === true;
        const v = rehydrate(raw);
        // Cache only a concrete primitive answer (a real node's constant); an
        // absent/null result keeps taking the fallback paths below uncached.
        if (constCache !== null && !isAbsent && CONST_NODE_PROPS.has(prop) &&
            (typeof v === "string" || typeof v === "number")) {
          constCache.set(prop, v);
        }
        const hostHasNoValue = isAbsent || v === null;
        if (v == null && (prop in t)) return Reflect.get(t, prop, receiver);
        // The global window: a name the host doesn't resolve falls back to a JS
        // global of the same name (an OWN globalThis prop — inherited names already
        // resolved via `prop in t` above), so e.g. a UMD bundle's
        // `globalThis.Stimulus = …` is visible as `window.Stimulus`.
        if (hostHasNoValue && isGlobalWindow(handle) && Object.hasOwn(globalThis, prop)) return globalThis[prop];
        // A legacy platform collection returns `undefined` (not the host's null)
        // for a string property that resolves to no value. An out-of-range array
        // index is `undefined` and does NOT fall back to a named lookup (so
        // `coll[2147483648]` is undefined even if an element's id is that digit
        // string); other unsupported strings (`coll[""]`, `coll["x"]`) too.
        if (hostHasNoValue && (arrayLike || named) && typeof prop === "string" && prop !== "length") {
          if (arrayLike && isArrayIndex(prop)) return undefined;
          if (!isNamedKey(prop)) return undefined;
        }
        return v;
      },
      set(t, prop, value, receiver) {
        if (typeof prop === "symbol") {
          t[prop] = value;
          if (proxyHandles.has(receiver)) pinned.set(handle, receiver);
          return true;
        }
        // A writable named collection (Storage/DOMStringMap) routes every string
        // assignment through its named setter, which takes precedence over a
        // prototype accessor — so `storage.x = v` never invokes a `Storage.prototype`
        // setter. Other objects defer to a matching prototype setter as usual.
        if (!(named && named.writable && typeof prop === "string") &&
            settersOf(Object.getPrototypeOf(t)).has(prop)) {
          Reflect.set(t, prop, value, receiver);
          return true;
        }
        // Legacy platform object with NO indexed setter: an array-index
        // assignment never becomes an expando — it is a no-op (sloppy) /
        // TypeError (strict), so the trap returns false. Objects WITH an indexed
        // setter (HTMLSelectElement/HTMLOptionsCollection) instead fall through
        // to the host set below, which runs the WebIDL "set an indexed property"
        // algorithm (add / replace / remove option).
        if (arrayLike && isArrayIndex(prop) && !indexedSetter) return false;
        // A read-only named property (HTMLCollection/NamedNodeMap) likewise
        // rejects — unless an own expando already shadows it (then update it).
        if (named && !named.writable && !Object.hasOwn(t, prop) && isNamedKey(prop)) return false;
        // The global window: a write to a name the host doesn't already
        // resolve becomes a JS global (window.X = … ≡ globalThis.X = …), so
        // window-attached and globalThis-attached globals converge on ONE
        // storage. A host-resolved property (location, navigator, a Ruby-side
        // stash, …) keeps routing to the host below. (globalThis is NOT this
        // proxy's prototype, so the plain assignment can't recurse here.)
        if (isGlobalWindow(handle)) {
          // Event handler IDL attributes (onload, onresize, …) must reach the
          // host so it registers a listener that actually fires; they read back
          // as null when unset, so the null-means-unresolved rule below would
          // otherwise divert them to a plain (never-firing) JS global. A
          // non-handler name still becomes a JS global (window.X ≡ globalThis.X).
          const isEventHandler = typeof prop === "string" && /^on[a-z]/.test(prop);
          if (!isEventHandler) {
            const cur = __rb_host_get(handle, prop);
            const curAbsent = cur !== null && typeof cur === "object" && cur.__rb_absent === true;
            if (curAbsent || rehydrate(cur) === null) {
              globalThis[prop] = value;
              return true;
            }
          }
        }
        // WebIDL [LegacyNullToEmptyString] DOMString setters coerce JS-side
        // (null → "", else ToString — so `innerHTML = 42` / `{toString…}` work and
        // a toString that throws propagates) before the value crosses into Ruby.
        if (NULL_TO_EMPTY_STRING_SETTERS.has(prop)) value = value === null ? "" : String(value);
        // A writable named property (Storage/DOMStringMap) has a DOMString named
        // setter: ToString-coerce the value JS-side (so `storage.x = 42` stores
        // "42", `= null` stores "null", and a `{toString}` object's throwing
        // toString propagates) before it crosses into Ruby.
        if (named && named.writable && typeof prop === "string") value = String(value);
        // A host property write may mutate the DOM (id/className/innerHTML/
        // style.color/dataset.x/…): invalidate attribute snapshots around it.
        bumpDomEpoch();
        const handled = __rb_host_set(handle, prop, dehydrateTop(value));
        bumpDomEpoch();
        // A throwing setter comes back as a tagged exception — re-throw it.
        if (handled && typeof handled === "object" && handled.__rb_exception__) {
          throw makeHostError(handled.__rb_exception__);
        }
        if (!handled) {
          t[prop] = value;
          // A genuine JS-side expando: pin the proxy so the node's JS state
          // outlives GC of this proxy (see the `pinned` declaration).
          if (proxyHandles.has(receiver)) pinned.set(handle, receiver);
        }
        return true;
      },
      // Array-like collections reflect their indices as own enumerable
      // properties so `hasOwnProperty(i)` / `Object.keys` / `{...spread}` see the
      // live children (testharness's assert_array_equals checks hasOwnProperty).
      // Named properties (HTMLCollection ids/names, dataset keys, attr names)
      // are reflected too — non-enumerable for [LegacyUnenumerableNamedProperties].
      getOwnPropertyDescriptor(t, prop) {
        if (typeof prop !== "symbol" && Object.hasOwn(t, prop)) return Reflect.getOwnPropertyDescriptor(t, prop);
        // The global window reflects JS globals as own properties. Clamp
        // configurable (a top-level `var` is non-configurable on globalThis,
        // but the proxy invariant forbids reporting non-configurable for a
        // prop absent from the target).
        if (typeof prop !== "symbol" && isGlobalWindow(handle) && Object.hasOwn(globalThis, prop)) {
          const d = Reflect.getOwnPropertyDescriptor(globalThis, prop);
          if (d) { d.configurable = true; return d; }
        }
        if (isIndexInRange(prop)) {
          // Indexed properties are enumerable + configurable but NOT writable
          // (these collections have no indexed property setter).
          return {
            value: rehydrate(__rb_host_get(handle, prop)),
            writable: false, enumerable: true, configurable: true,
          };
        }
        if (isNamedKey(prop) && !namedShadowedByProto(t, prop)) {
          return {
            value: rehydrate(__rb_host_get(handle, prop)),
            writable: named.writable, enumerable: named.enumerable, configurable: true,
          };
        }
        return Reflect.getOwnPropertyDescriptor(t, prop);
      },
      defineProperty(t, prop, desc) {
        // Cannot redefine a live indexed or read-only named property.
        if (arrayLike && isArrayIndex(prop)) return false;
        if (named && !named.writable && !Object.hasOwn(t, prop) && isNamedKey(prop)) return false;
        // A writable named collection (Storage/DOMStringMap) has a named setter:
        // `Object.defineProperty(storage, k, {value})` routes to it (ToString-
        // coerced) rather than planting a JS expando that the named getter can't
        // see. Only for a plain data descriptor targeting a non-own property.
        if (named && named.writable && typeof prop === "string" && !Object.hasOwn(t, prop) &&
            desc && !desc.get && !desc.set && ("value" in desc)) {
          bumpDomEpoch();
          __rb_host_set(handle, prop, dehydrateTop(String(desc.value)));
          bumpDomEpoch();
          return true;
        }
        return Reflect.defineProperty(t, prop, desc);
      },
      deleteProperty(t, prop) {
        if (typeof prop !== "symbol" && Object.hasOwn(t, prop)) return Reflect.deleteProperty(t, prop);
        // The global window: deleting a JS global through the window drops it
        // from globalThis (the shared namespace).
        if (typeof prop !== "symbol" && isGlobalWindow(handle) && Object.hasOwn(globalThis, prop)) {
          return delete globalThis[prop];
        }
        if (isIndexInRange(prop)) return false;
        if (named && typeof prop === "string") {
          if (named.writable) {
            // Named deleter (dataset): remove the backing attribute — a DOM
            // mutation, so invalidate attribute snapshots.
            bumpDomEpoch();
            if (rehydrate(__rb_host_delete(handle, prop))) return true;
          } else if (isNamedKey(prop)) {
            return false; // read-only named property cannot be deleted
          }
        }
        return Reflect.deleteProperty(t, prop);
      },
      ownKeys(t) {
        const keys = Reflect.ownKeys(t);
        if (!arrayLike && !named) return keys;
        const n = arrayLike ? liveLength() : 0;
        const result = [];
        for (let i = 0; i < n; i++) result.push(String(i));
        for (const nm of namedKeys()) {
          if (result.indexOf(nm) === -1 && !namedShadowedByProto(t, nm)) result.push(nm);
        }
        // Then expandos / symbols that don't collide with an index or named key.
        for (const k of keys) {
          if (typeof k !== "symbol" && isArrayIndex(k) && Number(k) < n) continue;
          if (result.indexOf(k) !== -1) continue;
          result.push(k);
        }
        return result;
      },
      has(t, prop) {
        // An out-of-range index on an array-like is genuinely absent (`2 in
        // nodeList` is false past its length). A supported named key is present.
        if (arrayLike && isArrayIndex(prop)) return Number(prop) < liveLength() || Reflect.has(t, prop);
        if (isNamedKey(prop)) return true;
        // A real expando, prototype member (incl. symbols like Symbol.iterator),
        // or ABI method is present.
        if (Reflect.has(t, prop)) return true;
        if (typeof prop === "symbol") return false;
        if (methods.has(prop) || prop === "length") return true;
        // The global window also reports its JS globals (`"Stimulus" in window`);
        // inherited names already answered true via Reflect.has(t) above.
        if (isGlobalWindow(handle) && Object.hasOwn(globalThis, prop)) return true;
        // Event-handler IDL attributes (onclick, oninput, …) exist on event
        // targets as null-default properties, so `("oninput" in document)` is
        // true even when unset — React's isEventSupported feature-detect relies
        // on this to use the native input event (else it falls back to a keydown
        // polyfill and controlled-input onChange never fires).
        if (typeof prop === "string" && /^on[a-z]/.test(prop)) return true;
        // Otherwise reflect the ABI: a property whose host value is non-null is
        // present; a null/absent one reports missing. We can't distinguish
        // present-but-null from genuinely-absent across the ABI, and reporting
        // missing is what lets `(prop in proxy)` feature-detection work — e.g.
        // Stimulus's extendEvent guards on `"immediatePropagationStopped" in
        // event` before installing its override, and a blanket `true` made it
        // skip the override so stopImmediatePropagation never halted siblings.
        // Dommy distinguishes a genuinely-absent property (host returns null)
        // from one that is present-but-undefined (it returns the UNDEFINED
        // sentinel, tagged `__rb_undefined`) — e.g. AbortSignal's `reason`
        // before abort — so report the latter present (`"reason" in signal`).
        if (constCache !== null && constCache.has(prop)) return true;
        const raw = __rb_host_get(handle, prop);
        // A genuinely-absent property (ABSENT tag) reports MISSING; a
        // present-but-undefined one (UNDEFINED tag) reports present.
        if (raw !== null && typeof raw === "object" && raw.__rb_absent) return false;
        if (raw !== null && typeof raw === "object" && raw.__rb_undefined) return true;
        return rehydrate(raw) != null;
      }
    };
  }

  function makeProxy(handle, iface, ce, suppressUpgrade) {
    const ref = cache.get(handle);
    if (ref) {
      const existing = ref.deref();
      if (existing) return existing;
    }
    // Reuse the cached per-interface descriptor when the handle crossed tagged
    // with a known interface — skipping the describe round trip. Otherwise (no
    // tag, or first sighting of this interface) describe once and cache it. The
    // custom-element tag is per-instance, so it comes from the handle tag (the
    // describe path falls back to the describe's own `ce`).
    let desc = (iface != null) ? descByInterface.get(iface) : undefined;
    let ceName = ce;
    if (!desc) {
      const d = __rb_host_describe(handle);
      desc = { name: d.name, chain: d.chain, methods: d.methods };
      if (d.name != null) descByInterface.set(d.name, desc);
      if (ceName === undefined) ceName = d.ce;
    }
    // 2d: method-name sets are per-interface; reuse across proxies of that type.
    let methods = methodsByInterface.get(desc.name);
    if (!methods) {
      methods = new Set(desc.methods);
      // The maplike iterator methods are served as live iterators from the
      // prototype (see ENTRIES_ITERABLES), so drop the Ruby array-returning
      // versions from the method set — otherwise `entries()` would return an
      // Array (no `.next()`) instead of an iterator.
      if (ENTRIES_ITERABLES.has(desc.name)) {
        for (const m of ["entries", "keys", "values"]) methods.delete(m);
      }
      methodsByInterface.set(desc.name, methods);
    }
    const target = (desc.chain && desc.chain.length)
      ? Object.create(protoForChain(desc.chain, 0))
      : {};
    // [LegacyUnforgeable] attributes live as own (non-configurable) accessors on
    // the instance target — `getOwnPropertyDescriptor(event, "isTrusted")` then
    // resolves them. The get trap still returns the live host value (it reads the
    // own prop via Reflect.get, invoking this shared getter).
    if (desc.chain) {
      for (const iface of desc.chain) {
        const attrs = UNFORGEABLE_ATTRS[iface];
        if (!attrs) continue;
        for (const name of attrs) {
          Object.defineProperty(target, name, {
            get: unforgeableGetter(name), enumerable: true, configurable: false,
          });
        }
      }
    }
    // 2c: memoize method functions per proxy so `el.foo === el.foo`.
    const isNode = !!(desc.chain && desc.chain.indexOf("Node") !== -1);
    const p = new Proxy(target, makeHandler(handle, methods, new Map(),
      ARRAY_LIKE_COLLECTIONS.has(desc.name), NAMED_PROP_COLLECTIONS.get(desc.name) || null,
      isNode, INDEXED_SETTER_INTERFACES.has(desc.name)));
    cache.set(handle, new WeakRef(p));
    proxyHandles.set(p, handle);
    // A DOM node's JS wrapper must be STABLE for the node's lifetime, exactly as
    // in a browser (same node -> the same object every time). Otherwise an
    // unretained node proxy — one JS holds only as a WeakMap/WeakSet KEY, not a
    // strong reference — can be GC'd and re-created as a DIFFERENT object on the
    // next access, silently breaking identity-keyed bookkeeping that real
    // frameworks rely on (Stimulus's deprecation Guide, React's fiber map, event
    // delegation, per-element memoization). So pin node proxies strongly (like an
    // expando-bearing proxy) instead of caching them only weakly. Residency is
    // bounded by the distinct nodes touched — the same set the Ruby-side wrapper
    // cache already retains. Non-node proxies stay weak + finalizer-released.
    if (isNode) {
      pinned.set(handle, p);
    } else {
      finalizers.register(p, handle);
    }
    // 1d: a Dommy-registered custom element node is upgraded to its JS class on
    // first crossing — so the constructor runs before any lifecycle callback.
    // Suppressed when the proxy IS the return value of an in-flight direct
    // construction (`new MyElement()`), whose ctor is already on the stack.
    if (ceName && !suppressUpgrade) upgradeElement(p, ceName);
    return p;
  }

  // ===== Custom elements (1d) =====

  // Run a JS custom element's constructor against an existing Dommy-backed proxy
  // (the construction-stack adoption proven by the Step 0 spike), making the
  // proxy an instance of the registered class with its constructor side effects.
  // Reverse of ceRegistry: the registered tag name for a constructor (the
  // active new.target of a direct `new MyElement()`), or undefined. Iterates —
  // a page defines a handful of elements, so a map's bookkeeping isn't worth it.
  function ceNameForCtor(ctor) {
    for (const [name, c] of ceRegistry) if (c === ctor) return name;
    return undefined;
  }

  function upgradeElement(proxy, name) {
    const ctor = ceRegistry.get(name);
    if (!ctor) return;
    constructionStack.push(proxy);
    try { Reflect.construct(ctor, [], ctor); }
    finally { constructionStack.pop(); }
  }

  // Ruby calls this when a registered custom element fires a lifecycle reaction.
  // makeProxy upgrades on first crossing, so the constructor has already run.
  function invokeLifecycle(handle, callback, args) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const p = makeProxy(handle);
    const fn = p[callback];
    if (typeof fn !== "function") return undefined;
    return dehydrateTop(fn.apply(p, rehydrate(args || [])));
  }

  // Hyphenated names the HTML spec reserves (SVG / MathML) — not valid custom
  // element names even though they match the production.
  const CE_RESERVED = new Set([
    "annotation-xml", "color-profile", "font-face", "font-face-src",
    "font-face-uri", "font-face-format", "font-face-name", "missing-glyph"
  ]);
  // https://html.spec.whatwg.org/#valid-custom-element-name — an ASCII-lower
  // start, a PCENChar run, and at least one "-".
  const CE_PCEN =
    "-._0-9a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D\\u037F-\\u1FFF" +
    "\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F\\u2C00-\\u2FEF\\u3001-\\uD7FF" +
    "\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}";
  const CE_NAME_RE = new RegExp("^[a-z][" + CE_PCEN + "]*-[" + CE_PCEN + "]*$", "u");
  function isValidCustomElementName(name) {
    return typeof name === "string" && CE_NAME_RE.test(name) && !CE_RESERVED.has(name);
  }

  // "element definition is running" flag — a define() reentered while running
  // (e.g. from a constructor-property getter) is a NotSupportedError.
  let ceDefinitionRunning = false;

  // WebIDL `sequence<DOMString>` conversion: the value must be iterable (a
  // non-iterable like a number throws a TypeError — unlike Array.from, which
  // returns []); each item is stringified. Exceptions from the iterator / items
  // propagate.
  function toDOMStringSequence(value) {
    const iterFn = (value === null || value === undefined) ? undefined : value[Symbol.iterator];
    if (typeof iterFn !== "function") {
      throw new TypeError("The value is not a sequence (it is not iterable)");
    }
    const result = [];
    for (const item of value) result.push(String(item));
    return result;
  }

  // customElements.define(name, JSClass): validate + read the constructor's
  // definition per WHATWG, register JS-side, and ask Ruby to wire a Dommy custom
  // element whose reactions route back through invokeLifecycle. Check order:
  // IsConstructor, name, running-flag, duplicate name, duplicate constructor;
  // then (flag set) prototype → callbacks → observedAttributes → disabledFeatures
  // → formAssociated.
  function defineCustomElement(name, ctor) {
    if (typeof ctor !== "function") {
      throw new TypeError("The custom element constructor must be a constructor");
    }
    if (!isValidCustomElementName(name)) {
      throw new DOMException("'" + name + "' is not a valid custom element name", "SyntaxError");
    }
    if (ceDefinitionRunning) {
      throw new DOMException("A custom element definition is already being processed", "NotSupportedError");
    }
    if (ceRegistry.has(name)) {
      throw new DOMException("An element with name '" + name + "' is already defined", "NotSupportedError");
    }
    for (const existing of ceRegistry.values()) {
      if (existing === ctor) {
        throw new DOMException("This constructor has already been registered", "NotSupportedError");
      }
    }

    ceDefinitionRunning = true;
    let observed = [];
    try {
      const proto = ctor.prototype;
      if (typeof proto !== "object" || proto === null) {
        throw new TypeError("The custom element constructor's prototype is not an object");
      }
      // Read each lifecycle reaction callback off the prototype, in spec order;
      // each must be undefined or a function. (connectedMoveCallback is skipped —
      // Dommy has no moveBefore.)
      const readCallback = (cb) => {
        const fn = proto[cb];
        if (fn !== undefined && typeof fn !== "function") {
          throw new TypeError("The " + cb + " callback is not a function");
        }
        return fn;
      };
      readCallback("connectedCallback");
      readCallback("disconnectedCallback");
      readCallback("adoptedCallback");
      const attributeChanged = readCallback("attributeChangedCallback");
      if (attributeChanged !== undefined) {
        const oa = ctor.observedAttributes;
        if (oa !== undefined) observed = toDOMStringSequence(oa);
      }
      // disabledFeatures / formAssociated are converted for their observable side
      // effects (Symbol.iterator access, iteration, ToBoolean); values unmodeled.
      const df = ctor.disabledFeatures;
      if (df !== undefined) toDOMStringSequence(df);
      if (ctor.formAssociated) {
        readCallback("formAssociatedCallback");
        readCallback("formResetCallback");
        readCallback("formDisabledCallback");
        readCallback("formStateRestoreCallback");
      }
    } finally {
      ceDefinitionRunning = false;
    }

    ceRegistry.set(name, ctor);
    __rb_define_custom_element(name, observed);
    const waiter = cePending.get(name);
    if (waiter) { cePending.delete(name); waiter.resolve(ctor); }
  }

  // whenDefined stays pending until the name is defined (spec semantics), so
  // `await customElements.whenDefined(x)` before define() doesn't resolve early.
  // The SAME promise is returned for a given still-undefined name each call
  // ([SameObject]-ish per spec), and define() resolves it.
  function whenDefinedCustomElement(name) {
    const ctor = ceRegistry.get(name);
    if (ctor) return Promise.resolve(ctor);
    let entry = cePending.get(name);
    if (!entry) {
      let resolve;
      const promise = new Promise((r) => { resolve = r; });
      entry = { promise, resolve };
      cePending.set(name, entry);
    }
    return entry.promise;
  }

  // Expose CustomElementRegistry as a real interface object with its operations
  // on the prototype (so `'define' in CustomElementRegistry.prototype`,
  // `customElements instanceof CustomElementRegistry`, and prototype reflection
  // work); `customElements` is its sole instance. The operations close over the
  // JS-side registry, so they ignore `this` (no host handle to route through).
  function CustomElementRegistry() { throw new TypeError("Illegal constructor"); }
  const cerProto = CustomElementRegistry.prototype;
  Object.defineProperty(cerProto, Symbol.toStringTag, { value: "CustomElementRegistry", configurable: true });
  const cerMethod = (key, fn) =>
    Object.defineProperty(cerProto, key, { value: fn, writable: true, enumerable: true, configurable: true });
  cerMethod("define", function (name, ctor) { return defineCustomElement(name, ctor); });
  cerMethod("get", function (name) { return ceRegistry.get(name); });
  cerMethod("getName", function (ctor) {
    if (typeof ctor !== "function") {
      throw new TypeError("The custom element constructor is not a constructor");
    }
    for (const [n, c] of ceRegistry) if (c === ctor) return n;
    return null;
  });
  cerMethod("whenDefined", function (name) {
    if (!isValidCustomElementName(name)) {
      return Promise.reject(new DOMException("'" + name + "' is not a valid custom element name", "SyntaxError"));
    }
    return whenDefinedCustomElement(name);
  });
  // Delegate manual upgrades to Dommy's registry (define() already upgrades
  // existing nodes; this covers subtrees attached without reactions).
  cerMethod("upgrade", function (root) { if (isProxy(root)) __rb_upgrade_custom_elements(root[HKEY]); });
  globalThis.CustomElementRegistry = CustomElementRegistry;
  globalThis.customElements = Object.create(cerProto);

  // ===== Unhandled-rejection detail capture (opt-in diagnostics) =====
  //
  // The engine stringifies a non-Error rejection reason to "[object Object]"
  // before Ruby sees it, hiding what actually failed (e.g. note.com's React
  // error). When installed, record a RICH description (message/stack, or the
  // own-property JSON) of each rejection AS IT HAPPENS — wrapping the Promise
  // constructor (so `.then`-chain and executor rejections are seen) and the
  // static reject — so the Ruby side can replace the detail-less report with the
  // truth. Behavior-preserving (only records), and only installed when asked.
  function describeRejection(reason) {
    try {
      if (reason !== null && typeof reason === "object" &&
          typeof reason.stack === "string" && typeof reason.message === "string") {
        return (reason.name || "Error") + ": " + reason.message + "\n" + reason.stack;
      }
      if (reason === null) return "null";
      if (reason === undefined) return "undefined";
      if (typeof reason === "object") {
        let json = null;
        try { json = JSON.stringify(reason, (k, v) => (typeof v === "function" ? "[Function]" : v)); } catch (e) {}
        const keys = Object.keys(reason).slice(0, 40).join(", ");
        return "[non-Error rejection] keys: {" + keys + "}" + (json ? " " + json.slice(0, 4000) : "");
      }
      return String(reason);
    } catch (e) { return "(rejection reason could not be described)"; }
  }
  function installRejectionTracker() {
    const P = globalThis.Promise;
    if (!P || P.__rbTracked) return;
    // Push to a Ruby buffer AT REJECT TIME (normal JS context, a safe crossing) —
    // NOT from the engine's rejection callback, where re-entering the VM is
    // unsafe. The Ruby side pairs it with the detail-less report by recency.
    const record = (reason) => {
      try { __rb_record_rejection_detail(describeRejection(reason)); } catch (e) {}
    };
    const Tracked = function (executor) {
      return Reflect.construct(P, [function (resolve, reject) {
        executor(resolve, function (reason) { record(reason); return reject(reason); });
      }], new.target || Tracked);
    };
    Tracked.prototype = P.prototype;
    Object.setPrototypeOf(Tracked, P); // inherit statics + Symbol.species
    const origReject = P.reject.bind(P);
    Tracked.reject = function (reason) { record(reason); return origReject(reason); };
    Tracked.__rbTracked = true;
    globalThis.Promise = Tracked;
  }

  // 1a: report the DOM interface chain of a host proxy, most-derived first
  // (e.g. ["HTMLDivElement","HTMLElement","Element","Node","EventTarget"]).
  // Returns null for non-proxies.
  function interfaceOf(proxy) {
    if (!isProxy(proxy)) return null;
    return __rb_host_describe(proxy[HKEY]);
  }

  return {
    makeProxy, invokeCallback, invokeJsRefHandleEvent, invokeJsRefAcceptNode, runScript, scheduleMicrotask,
    bumpDomEpoch,
    // `tag` is the public top-level dehydrate (used by engine gems' eval_tagged
    // for evaluate() results): it tags a top-level `undefined` so
    // `evaluate("undefined")` yields UNDEFINED on every engine, not just those
    // whose value marshalling distinguishes undefined from null.
    tag: dehydrateTop, interfaceOf,
    // A host-PromiseValue deferred whose resolve runs the full §2.3 resolution
    // procedure — the Promises/A+ conformance adapter's primitive.
    makeHostDeferred,
    // Opt-in rejection-detail capture (see installRejectionTracker).
    installRejectionTracker,
    seedInterfaces, invokeLifecycle, attachStatics, exposeConstructorsOnWindow,
    // wasm host bridge (handle-oriented access for a wasm guest)
    wasmGlobalRef, wasmEval, wasmGet, wasmSet, wasmCall, wasmApply, wasmNew,
    wasmTypeof, wasmToString, wasmStrictEqual, wasmIsNull, wasmInstanceof,
    wasmMakeCallback, wasmReleaseRef,
  };
})();
