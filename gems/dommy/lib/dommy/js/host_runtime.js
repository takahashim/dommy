// JS half of the Dommy <-> Ruby DOM bridge. Loaded once per backend and
// eval'd into the VM. Defines globalThis.__rbHost.{makeProxy, invokeCallback,
// tag, interfaceOf, seedInterfaces}.
//
// Values crossing the boundary are tagged: a bridge-able Ruby object is
// `{ __rb_handle: id }`, a JS function passed to Ruby is `{ __rb_callback: id }`.
globalThis.__rbHost = (function () {
  // The platform's own enumerations — what interfaces, members, constants and
  // handler attributes the specs declare — live in webidl_tables.js, evaluated
  // just before this file. They are bound here as plain consts so the code below
  // reads (and costs) the same as when they were written inline.
  const {
    ARRAY_LIKE_COLLECTIONS, INDEXED_SETTER_INTERFACES, ENTRIES_ITERABLES, PAIR_ITERABLE_COLLECTIONS,
    NAMED_PROP_COLLECTIONS, NULL_TO_EMPTY_STRING_SETTERS,
    INTERFACE_NULL_TO_EMPTY_STRING_SETTERS, FORM_VALUE_FIELDS, READONLY_ATTRS,
    UNFORGEABLE_ATTRS, UNFORGEABLE_METHODS, UNFORGEABLE_DATA, FIXED_SHAPE_INTERFACES,
    INTERFACE_CONSTANTS, INTERFACE_MEMBERS, INTERFACE_UNSCOPABLES, PROTO_RESOLVED_METHODS,
    NODE_OR_STRING_METHODS, ELEMENT_HANDLER_ATTRIBUTES, WINDOW_REFLECTED_HANDLERS,
    BODY_REFLECTED_HANDLERS, METHOD_ARITY, INTERFACE_METHOD_ARITY, CONSTRUCTOR_ARITY,
    VOID_METHODS, INTERFACE_VOID_METHODS, JS_GLOBALS,
  } = globalThis.__rbIdl;

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
  // proxy -> the interface name it was built for. A Ruby object can be freed and
  // its handle id reused for a DIFFERENT object, so a cached proxy is only
  // trustworthy while it still describes the same interface — otherwise the new
  // object would come back wearing the previous one's prototype (and expandos).
  const proxyInterfaces = new WeakMap();
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

  const unforgeableGetters = new Map();
  function unforgeableGetter(name) {
    let fn = unforgeableGetters.get(name);
    if (!fn) {
      fn = function () { return rehydrate(__rb_host_get(this[HKEY], name)); };
      unforgeableGetters.set(name, fn);
    }
    return fn;
  }

  const unforgeableSetters = new Map();
  function unforgeableSetter(name) {
    let fn = unforgeableSetters.get(name);
    if (!fn) {
      // A location setter navigates, which is a DOM mutation like any other —
      // hostSet brackets it with the epoch bumps that says so.
      fn = function (value) { hostSet(this[HKEY], name, value); };
      unforgeableSetters.set(name, fn);
    }
    return fn;
  }

  // One function per (interface, operation), shared by every instance — so it
  // takes its handle from `this`, and must therefore check `this`. WebIDL says
  // a receiver of the wrong interface is a TypeError, and a stringifier that is
  // an own property is exactly the one pages call as
  // `location.toString.call(somethingElse)`.
  const unforgeableMethods = new Map();
  function unforgeableMethod(iface, name) {
    const key = iface + "." + name;
    let fn = unforgeableMethods.get(key);
    if (!fn) {
      fn = function (...args) {
        // The chain, not the interface name: an operation an interface declares
        // is inherited by everything derived from it, and `document.location`'s
        // neighbours are HTMLDocument instances, not Document ones.
        if (!isProxy(this) || !interfaceChainOf(this).includes(iface)) {
          throw new TypeError("Illegal invocation: " + iface + "." + name + " called on a different object");
        }
        bumpDomEpoch();
        try {
          return hostCallResult(name, __rb_host_call(this[HKEY], name, dehydrateArgs(args)), iface);
        } finally {
          bumpDomEpoch();
        }
      };
      Object.defineProperty(fn, "name", { value: name, configurable: true });
      withArity(fn, name, iface);
      unforgeableMethods.set(key, fn);
    }
    return fn;
  }

  // A proxy's interface chain (["HTMLDocument", "Document", "Node", …]), from
  // the per-interface describe the proxy was built from. Empty for an object
  // whose interface was never named.
  function interfaceChainOf(proxy) {
    const desc = descByInterface.get(proxyInterfaces.get(proxy));
    return (desc && desc.chain) || [];
  }

  // The [LegacyUnforgeable] attributes along an interface chain as
  // name -> writable, or null when it has none — which is every interface but
  // three, so the set trap's check is a null test on the hot path.
  function unforgeableAttrsOf(chain) {
    let attrs = null;
    for (const iface of chain || []) {
      for (const [name, writable] of Object.entries(UNFORGEABLE_ATTRS[iface] || {})) {
        (attrs ||= new Map()).set(name, writable);
      }
    }
    return attrs;
  }

  // Plant one interface's [LegacyUnforgeable] members on an instance's target.
  function installUnforgeable(target, iface) {
    for (const [name, writable] of Object.entries(UNFORGEABLE_ATTRS[iface] || {})) {
      Object.defineProperty(target, name, {
        get: unforgeableGetter(name),
        set: writable ? unforgeableSetter(name) : undefined,
        enumerable: true, configurable: false,
      });
    }
    for (const name of UNFORGEABLE_METHODS[iface] || []) {
      Object.defineProperty(target, name, {
        value: unforgeableMethod(iface, name),
        writable: false, enumerable: true, configurable: false,
      });
    }
    for (const [name, value] of UNFORGEABLE_DATA[iface] || []) {
      Object.defineProperty(target, name, {
        value, writable: false, enumerable: false, configurable: false,
      });
    }
  }

  function coerceNodeOrString(arg) {
    return isProxy(arg) ? arg : String(arg);
  }

  function isHandlerAttribute(el, name) {
    if (ELEMENT_HANDLER_ATTRIBUTES.has(name)) return true;
    if (!WINDOW_REFLECTED_HANDLERS.has(name)) return false;

    try {
      const tag = el.tagName;
      return tag === "BODY" || tag === "FRAMESET";
    } catch (e) {
      return false;
    }
  }

  // Setting an on* content attribute at runtime (`el.setAttribute("onclick",
  // code)`) must compile+activate the handler synchronously, exactly like the
  // boot-time inline-handler wiring (script_boot). Mirrors its scope chain —
  // [element, form owner, document] — so `onclick="getElementById(…)"` or a
  // form control's bare member resolve, and assigns via the on* IDL setter
  // (el.onclick = fn), which the proxy routes to the Ruby handler registry.
  // A null code (removeAttribute) clears the handler. Invalid source is ignored.
  function wireInlineHandler(el, name, code) {
    try {
      if (!isHandlerAttribute(el, name)) return;
      if (code == null) { el[name] = null; return; }
      let src = "with(this){\n" + String(code) + "\n}";
      try { if (el.form) src = "with(this.form){\n" + src + "\n}"; } catch (e) { /* no form owner */ }
      src = "with(document){\n" + src + "\n}";
      let fn;
      try { fn = new Function("event", src); }
      catch (e) { fn = new Function("event", String(code)); } // fall back to plain scope
      el[name] = fn;
    } catch (e) { /* syntactically invalid handler: skip, non-fatal */ }
  }

  // Compile every on* content attribute already in the document into a live
  // handler. Run once at boot, after parsing and before scripts (matching the
  // spec, where content attributes are set as the document is parsed), and
  // replayed whenever an element carrying one turns up later (cloneNode,
  // innerHTML, a template's fragment). Idempotent: an element whose handler is
  // already compiled is left alone.
  //
  // The scan is selector-driven — only elements carrying a known handler
  // attribute — rather than a walk of every element. A handler on body/frameset
  // for a window-reflected event belongs on the WINDOW, so it is wired with
  // addEventListener; the element's own load never fires, which is what makes
  // `<body onload>` work. Everything else goes through wireInlineHandler, the
  // same compilation the runtime `setAttribute("on*")` path uses.
  function wireInlineHandlers() {
    const selector = [...ELEMENT_HANDLER_ATTRIBUTES, ...WINDOW_REFLECTED_HANDLERS]
      .map((name) => "[" + name + "]").join(",");
    const body = document.body;
    for (const el of document.querySelectorAll(selector)) {
      const onBody = el === body || el.tagName === "FRAMESET";
      for (const name of el.getAttributeNames()) {
        if (!ELEMENT_HANDLER_ATTRIBUTES.has(name) &&
            !(onBody && WINDOW_REFLECTED_HANDLERS.has(name))) continue;
        if (onBody && BODY_REFLECTED_HANDLERS.has(name)) {
          try {
            window.addEventListener(name.slice(2), new Function("event", el.getAttribute(name)));
          } catch (e) { /* syntactically invalid handler: skip, non-fatal */ }
        } else if (typeof el[name] !== "function") {
          wireInlineHandler(el, name, el.getAttribute(name));
        }
      }
    }
  }

  function withArity(fn, name, iface) {
    const own = iface === undefined ? undefined : INTERFACE_METHOD_ARITY[iface];
    // Own entries only: a plain-object table would otherwise hand `toString`
    // (or `constructor`, `valueOf`, ...) the inherited Object.prototype function.
    const table = own && Object.prototype.hasOwnProperty.call(own, name) ? own : METHOD_ARITY;
    const n = Object.prototype.hasOwnProperty.call(table, name) ? table[name] : undefined;
    if (n !== undefined) Object.defineProperty(fn, "length", { value: n, configurable: true });
    return fn;
  }

  // A Ruby method returns nil for "nothing", which crosses as null; for an
  // operation whose WebIDL return type is undefined the caller must instead see
  // undefined (`el.setAttribute(...) === undefined`). `iface` settles the names
  // whose return type depends on which interface declares them.
  function hostCallResult(name, raw, iface) {
    const value = rehydrate(raw);
    if (value !== null) return value;
    const perInterface = iface === undefined ? undefined : INTERFACE_VOID_METHODS[iface];
    return (perInterface && perInterface.indexOf(name) !== -1) || VOID_METHODS.has(name) ? undefined : value;
  }

  // The shared delegating stubs, created once and reused on every prototype. A
  // stub reached through the prototype (`Element.prototype.remove.call(el)`, or
  // a `super.method()` in a custom element) must invalidate the DOM-epoch caches
  // around a mutating call exactly as the proxy's own get trap does — otherwise
  // the DOM changes underneath a cached parentNode / attribute snapshot and the
  // next read hands back the state from before the call.
  function memberMethodStub(name, iface) {
    const coerce = NODE_OR_STRING_METHODS.has(name);
    const readOnly = NON_MUTATING_METHODS.has(name);
    const stub = withArity(function (...args) {
      // Resolve back through the receiver: the proxy get trap returns the
      // specialized per-proxy wrapper (epoch bumps, cached getAttribute, the
      // dispatchEvent fast path and its JS-event handling), which prototype
      // extraction (Interface.prototype.m.call(el, …)) must not bypass. The
      // get trap intercepts before the prototype, so this doesn't recurse —
      // except for collections' PROTO_RESOLVED_METHODS, which resolve to this
      // very stub; the self-check falls through to the raw call then, which
      // still brackets a mutating call with the epoch bumps itself.
      if (isProxy(this)) {
        const fn = this[name];
        if (typeof fn === "function" && fn !== stub) return fn.apply(this, args);
      }
      const wire = dehydrateArgs(coerce ? args.map(coerceNodeOrString) : args);
      return readOnly
        ? hostCallResult(name, __rb_host_call(this[HKEY], name, wire), iface)
        : callMutating(this[HKEY], name, wire, iface);
    }, name, iface);
    return stub;
  }

  function callMutating(handle, name, wire, iface) {
    bumpDomEpoch();
    try {
      return hostCallResult(name, __rb_host_call(handle, name, wire), iface);
    } finally {
      bumpDomEpoch();
    }
  }

  // Every write of a host property is the same four steps, so they live here
  // rather than at each site that writes one — the proxy's set and defineProperty
  // traps, the prototype setter stub, a [LegacyUnforgeable] setter, and a
  // form-control value accessor. A write can mutate the DOM (id / className /
  // style.color / dataset.x / select.value), so the DOM epoch is bumped on both
  // sides of it: before, so a reentrant callback the host runs can't read a
  // stale snapshot, and after, so this write's own mutations invalidate later
  // reads. A setter the spec says throws comes back tagged and is re-thrown.
  // The return value is the host's answer to "did I claim this write?" — false
  // means the caller should keep the value JS-side as an expando.
  function hostSet(handle, name, value) {
    bumpDomEpoch();
    const handled = __rb_host_set(handle, name, dehydrateTop(value));
    bumpDomEpoch();
    if (handled && typeof handled === "object" && handled.__rb_exception__) {
      throw makeHostError(handled.__rb_exception__);
    }
    return handled;
  }

  function memberGetStub(name) {
    return function () { return rehydrate(__rb_host_get(this[HKEY], name)); };
  }
  // [LegacyNullToEmptyString]: null becomes "" rather than "null". Declared per
  // attribute in the IDL, so a name that is null-to-empty on one interface and a
  // plain DOMString on another (`value`, on the text controls and on nothing
  // else) is answered by the interface's own list.
  function nullToEmptyString(iface, name) {
    if (NULL_TO_EMPTY_STRING_SETTERS.has(name)) return true;
    const own = iface === undefined ? undefined : INTERFACE_NULL_TO_EMPTY_STRING_SETTERS[iface];
    return !!own && own.indexOf(name) !== -1;
  }

  function memberSetStub(name, iface) {
    // Mirror the proxy set trap for a reflected attribute: [LegacyNullToEmptyString]
    // coercion, then the shared host write (the set trap delegates instance
    // writes to this prototype setter, so it must invalidate the same caches).
    // Called with the element as `this`.
    return function (v) {
      if (nullToEmptyString(iface, name)) v = v === null ? "" : String(v);
      hostSet(this[HKEY], name, v);
    };
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
      def(mname, { value: memberMethodStub(mname, name), writable: true, enumerable: true, configurable: true }));
    (members.g || []).forEach((gname) =>
      def(gname, { get: memberGetStub(gname), enumerable: true, configurable: true }));
    (members.p || []).forEach((pname) =>
      def(pname, { get: memberGetStub(pname), set: memberSetStub(pname, name), enumerable: true, configurable: true }));
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
      return tagThrow(e);
    }
  }

  // Tag a value thrown by a callback (`{__rb_cb_threw__: …}`) so the Ruby side
  // can swallow, re-raise, or report it. An object/function keeps its identity
  // through the round trip via a JS ref — even a plain object (`throw
  // {name:"x"}`), which dehydrate would flatten to a map and
  // assert_throws_exactly compares by identity — and carries a best-effort
  // label (its `.message`, else its String form) so a reported error's
  // `event.message` is meaningful rather than "[object]".
  function tagThrow(e) {
    const tagged = tagValue(e);
    return { __rb_cb_threw__: tagged };
  }

  // An error's `stack`, carried across with it. Ruby cannot reach through an
  // opaque ref to read the property, and reporting the error needs the frames to
  // say where the page failed — so both values that might be reported take them
  // along: one thrown (tagValue) and one merely handed over, like the argument
  // to `reportError` (dehydrate).
  function attachJsStack(tag, v) {
    try {
      if (v.stack) tag.__rb_js_stack = String(v.stack);
    } catch (_) { /* a stack getter threw: no frames */ }
    return tag;
  }

  // Cross a value to Ruby with its identity intact, carrying the detail Ruby
  // cannot read back off an opaque ref: its `message` as a label and its
  // `stack` as frames. A primitive has neither and just dehydrates.
  function tagValue(v) {
    if (v === null || (typeof v !== "object" && typeof v !== "function")) return dehydrate(v);

    const tag = { __rb_js_ref: registerJsRef(v) };
    try {
      const m = v.message != null ? String(v.message) : String(v);
      if (m) tag.__rb_js_label = m;
    } catch (_) { /* a message/toString getter threw: no label */ }
    attachJsStack(tag, v);
    try {
      // The kind of thing it is, for a host log that would otherwise only be
      // able to name the Ruby wrapper it arrived in.
      const c = v.constructor;
      if (c && c.name) tag.__rb_js_name = String(c.name);
    } catch (_) { /* a constructor getter threw: no name */ }
    return tag;
  }

  // Promises reported to the host as unhandled, so a later "handled" for one we
  // never reported (rejected before the hook was installed) is ignored. A
  // WeakSet, so remembering a promise does not keep it alive.
  const reportedRejections = new WeakSet();

  // The engine's promise-rejection hook (see the engine gem's
  // `promise_rejection_hook=`). Called at the end of a microtask checkpoint with
  // the REAL promise and reason, which is what lets `event.reason` be the value
  // the page threw and `event.promise` exist at all.
  //
  // Throwing here would drop the rest of the batch, so nothing is allowed out.
  function onPromiseRejection(type, promise, reason) {
    try {
      if (type === "rejectionhandled") {
        if (!reportedRejections.has(promise)) return;
        reportedRejections.delete(promise);
      } else {
        reportedRejections.add(promise);
      }
      __rb_promise_rejection(String(type), tagValue(promise), tagValue(reason));
    } catch (_) { /* the batch's remaining notifications still go out */ }
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
      // A callback-interface object — an EventListener ({ handleEvent }, e.g.
      // Stimulus's action listeners) or a NodeFilter ({ acceptNode }) — crosses
      // as a live reference even when it is a PLAIN object: it must keep its
      // identity, be invoked with itself as `this`, have handleEvent /
      // acceptNode fetched fresh on each call (WebIDL looks the operation up
      // per invocation, so a getter runs each time and a non-callable one is a
      // TypeError then), and let a thrown value propagate — none of which
      // survives flattening to a map. Detected with `in`, never a Get, so
      // merely registering the listener or constructing the walker runs no
      // getter.
      const proto = Object.getPrototypeOf(v);
      const isExotic = proto !== Object.prototype && proto !== null;
      const handlesEvents = "handleEvent" in v;
      const acceptsNodes = "acceptNode" in v;
      if (isExotic || handlesEvents || acceptsNodes) {
        const ref = { __rb_js_ref: registerJsRef(v) };
        if (handlesEvents) ref.__rb_handle_event = true;
        if (acceptsNodes) ref.__rb_accept_node = true;
        // An Error crossing as an opaque ref still needs a readable label and its
        // frames: the host cannot reach through a ref to read `.message` or
        // `.stack`, so an error the page hands us (`reportError(new
        // Error("boom"))`) would otherwise be logged — and shown as
        // `event.message` — as "[object]", and reported at line 0 of nowhere.
        // Only Errors are described, and by brand rather than `instanceof` so one
        // from another realm is recognised too; every other opaque value is left
        // bare.
        if (Object.prototype.toString.call(v) === "[object Error]") {
          try {
            const m = v.message != null ? String(v.message) : "";
            if (m) ref.__rb_js_label = m;
          } catch (_) { /* a message getter threw: no label */ }
          attachJsStack(ref, v);
        }
        return ref;
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
  // rehydrated to a proxy first. WebIDL "call a user object's operation": Get
  // handleEvent ONCE per invocation (a getter runs each dispatch; a throw while
  // getting propagates) then require it callable — a non-callable handleEvent
  // is a TypeError. A thrown value (from the getter, the callability check, or
  // the call) is tagged with its identity, like invokeCallback, so the Ruby
  // side re-raises it as a ThrowValue and reports it as a window `error` event
  // (event.error must be the SAME object per WPT).
  function invokeJsRefHandleEvent(ref, event) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const o = jsRefs.get(ref);
    if (!o) return undefined;
    try {
      const handler = o.handleEvent;
      if (typeof handler !== "function") {
        throw new TypeError("EventListener.handleEvent is not a function");
      }
      return dehydrateTop(handler.call(o, rehydrate(event)));
    } catch (e) {
      return tagThrow(e);
    }
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
      return tagThrow(e);
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
      if ("__rb_handle" in v) {
        // A dispatch-in-flight host twin resolves to its JS event, so a
        // listener's argument IS the object the caller constructed.
        const jsEvent = jsEventByHandle.get(v.__rb_handle);
        if (jsEvent !== undefined) return jsEvent;
        return makeProxy(v.__rb_handle, v.__rb_if, v.__rb_ce);
      }
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
      if ("__rb_handle" in v) {
        // A dispatch-in-flight host twin resolves to its JS event, so a
        // listener's argument IS the object the caller constructed.
        const jsEvent = jsEventByHandle.get(v.__rb_handle);
        if (jsEvent !== undefined) return jsEvent;
        return makeProxy(v.__rb_handle, v.__rb_if, v.__rb_ce);
      }
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

  // ===== JS-side Event/CustomEvent (docs/js-side-events-design.md) =====
  // `new Event/CustomEvent` builds a pure-JS object on the seeded interface
  // prototype — no crossing. A host twin is materialized only when a dispatch
  // takes the slow (listened) path; while it's in flight, live state
  // (defaultPrevented/eventPhase/target/…) delegates to the twin, and
  // jsEventByHandle lets rehydrate hand listeners the IDENTICAL JS object.
  const JS_EVENT = Symbol("dommyJsEvent");
  const jsEventByHandle = new Map(); // twin handle -> JS event, during dispatch
  // Shared accessor/method functions (WPT checks e.g. the isTrusted getter is
  // the SAME function across instances), reading state via this[JS_EVENT].
  const jsEventState = (self) => self[JS_EVENT];
  const JS_EVENT_MEMBERS = {
    type: { get: function () { return jsEventState(this).type; } },
    bubbles: { get: function () { return jsEventState(this).bubbles; } },
    cancelable: { get: function () { return jsEventState(this).cancelable; } },
    composed: { get: function () { return jsEventState(this).composed; } },
    timeStamp: { get: function () { return jsEventState(this).timeStamp; } },
    defaultPrevented: { get: function () {
      const s = jsEventState(this); return s.host ? s.host.defaultPrevented : s.canceled;
    } },
    eventPhase: { get: function () {
      const s = jsEventState(this); return s.host ? s.host.eventPhase : 0;
    } },
    target: { get: function () {
      const s = jsEventState(this); return s.host ? s.host.target : s.target;
    } },
    srcElement: { get: function () {
      const s = jsEventState(this); return s.host ? s.host.target : s.target;
    } },
    currentTarget: { get: function () {
      const s = jsEventState(this); return s.host ? s.host.currentTarget : null;
    } },
    returnValue: {
      get: function () { const s = jsEventState(this); return s.host ? s.host.returnValue : !s.canceled; },
      set: function (v) {
        const s = jsEventState(this);
        if (s.host) { s.host.returnValue = v; return; }
        // Legacy: falsy cancels (when cancelable); truthy does not un-cancel.
        if (!v && s.cancelable) s.canceled = true;
      },
    },
    cancelBubble: {
      get: function () { const s = jsEventState(this); return s.host ? s.host.cancelBubble : s.stopped; },
      set: function (v) { if (v) this.stopPropagation(); },
    },
    preventDefault: { value: function () {
      const s = jsEventState(this);
      if (s.host) { s.host.preventDefault(); return; }
      if (s.cancelable) s.canceled = true;
    } },
    stopPropagation: { value: function () {
      const s = jsEventState(this);
      if (s.host) s.host.stopPropagation();
      s.stopped = true;
    } },
    stopImmediatePropagation: { value: function () {
      const s = jsEventState(this);
      if (s.host) s.host.stopImmediatePropagation();
      s.stopped = true;
    } },
    // Legacy re-init: a no-op while the event is being dispatched.
    initEvent: { value: function (type, bubbles, cancelable) {
      const s = jsEventState(this);
      if (s.host) return;
      s.type = String(type);
      s.bubbles = !!bubbles;
      s.cancelable = !!cancelable;
      s.canceled = false;
      s.stopped = false;
      s.target = null;
    } },
    // Outside dispatch the composed path is empty per spec.
    composedPath: { value: function () {
      const s = jsEventState(this); return s.host ? s.host.composedPath() : [];
    } },
  };
  const JS_EVENT_DETAIL = { get: function () { return jsEventState(this).detail; }, enumerable: true, configurable: true };
  const JS_EVENT_INIT_CUSTOM = { value: function (type, bubbles, cancelable, detail) {
    const s = jsEventState(this);
    if (s.host) return; // no-op while dispatching, like initEvent
    this.initEvent(type, bubbles, cancelable);
    s.detail = detail === undefined ? null : detail;
  }, writable: true, enumerable: false, configurable: true };
  // [LegacyUnforgeable]: an own, non-configurable accessor, like host events'.
  const JS_EVENT_IS_TRUSTED = { get: function () { return false; }, enumerable: true, configurable: false };

  // A per-interface prototype carrying the JS-event members ONCE (they shadow
  // the seeded interface stubs, which delegate through a host handle a JS
  // event doesn't have; each member reads this[JS_EVENT] so it works as an
  // inherited accessor). Built lazily, so construction installs only the two
  // genuinely per-instance own props (the state slot + unforgeable isTrusted)
  // rather than ~20 defineProperty calls per event.
  function defineJsEventMembers(target, name) {
    for (const key of Object.keys(JS_EVENT_MEMBERS)) {
      const m = JS_EVENT_MEMBERS[key];
      const d = { configurable: true };
      if (m.value) { d.value = m.value; d.writable = true; d.enumerable = false; }
      else { d.get = m.get; d.enumerable = true; if (m.set) d.set = m.set; }
      Object.defineProperty(target, key, d);
    }
    if (name === "CustomEvent") {
      Object.defineProperty(target, "detail", JS_EVENT_DETAIL);
      Object.defineProperty(target, "initCustomEvent", JS_EVENT_INIT_CUSTOM);
    }
  }

  const jsEventProtoByName = new Map();
  function jsEventProtoFor(name) {
    let proto = jsEventProtoByName.get(name);
    if (proto) return proto;
    proto = Object.create(protos.get(name));
    defineJsEventMembers(proto, name);
    jsEventProtoByName.set(name, proto);
    return proto;
  }

  function makeJsEvent(name, type, dict) {
    const ev = Object.create(jsEventProtoFor(name));
    const nowv = (typeof performance === "object" && performance !== null &&
      typeof performance.now === "function") ? performance.now() : 0;
    const state = {
      name, type,
      bubbles: dict.bubbles === true, cancelable: dict.cancelable === true,
      composed: dict.composed === true,
      detail: "detail" in dict ? dict.detail : null,
      // Strictly positive: creation always follows the time origin, but the
      // clock's first read can round to 0 (WPT asserts timeStamp > 0).
      timeStamp: nowv > 0 ? nowv : 0.001,
      canceled: false, stopped: false, target: null, host: null,
    };
    Object.defineProperty(ev, JS_EVENT, { value: state });
    // isTrusted is [LegacyUnforgeable] — an OWN non-configurable accessor
    // (getOwnPropertyDescriptor(ev, "isTrusted") must resolve it), so it
    // stays per-instance even though every event answers false.
    Object.defineProperty(ev, "isTrusted", JS_EVENT_IS_TRUSTED);
    return ev;
  }

  function constructInterface(name, args) {
    if (name === "Event" || name === "CustomEvent") {
      const coerced = coerceConstructorArgs(name, args);
      return makeJsEvent(name, coerced[0], coerced[1]);
    }
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
      const built = constructInterface(name, args);
      // A JS subclass (`class Foo extends Event {}` / `extends EventTarget`)
      // reaches its base interface ctor via super(); the base returns a fresh
      // host-backed proxy, which then becomes the subclass instance. Stamp
      // new.target's prototype so `new Foo() instanceof Foo` holds and Foo's
      // added members resolve. Node/custom-element subclasses were already
      // handled (and returned) by the construction-stack / HTMLElement paths
      // above, so reaching here with nt !== ctor is a plain interface subclass.
      if (nt !== ctor && built && typeof built === "object") {
        // A JS-side event (built[JS_EVENT]) carries its members on an
        // intermediate prototype that this setPrototypeOf discards; reinstall
        // them as own props so a subclassed Event/CustomEvent still works.
        const evState = built[JS_EVENT];
        Object.setPrototypeOf(built, nt.prototype);
        if (evState !== undefined) defineJsEventMembers(built, evState.name);
      }
      return built;
    };
    Object.defineProperty(ctor, "name", { value: name, configurable: true });
    // WebIDL constructor `length` = the required argument count; the stub uses a
    // rest parameter, so stamp the spec's number where it is not 0.
    const ctorArity = CONSTRUCTOR_ARITY[name];
    if (ctorArity !== undefined) Object.defineProperty(ctor, "length", { value: ctorArity, configurable: true });
    ctor.prototype = proto;
    Object.defineProperty(proto, "constructor", { value: ctor, configurable: true, writable: true });
    // [Unscopable] members -> a null-prototyped @@unscopables object on the
    // prototype (WebIDL: configurable, non-writable, non-enumerable).
    const unscopables = INTERFACE_UNSCOPABLES[name];
    if (unscopables) {
      const u = Object.create(null);
      for (const m of unscopables) u[m] = true;
      Object.defineProperty(proto, Symbol.unscopables, { value: u, configurable: true });
    }
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
      // The pair methods belong to the interfaces whose IDL declares
      // `iterable<>`; an indexed getter alone gets @@iterator and no more, which
      // is what an HTMLCollection or a CSSRuleList has.
      if (PAIR_ITERABLE_COLLECTIONS.has(name)) {
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
          // A throwing host setter (a file input's `value =`) propagates, and
          // the write invalidates the caches like any other — `select.value = x`
          // reorders the option elements' selectedness, which a stale
          // per-epoch snapshot would otherwise answer from.
          set(v) { hostSet(this[HKEY], field, v); },
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
      // Share the interface prototype (so `new Image() instanceof HTMLImageElement`)
      // as a non-writable/enumerable/configurable own property, per WebIDL — a
      // constructor's `prototype` is not writable.
      Object.defineProperty(ctor, "prototype", { value: proto, writable: false, enumerable: false, configurable: false });
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
    // (WPT reaches for `(root.ownerDocument).defaultView.TypeError`). The same
    // list the forced pass at the end of this function uses — a window mirrors
    // one set of native globals, so there is one table of them.
    names.push(...JS_GLOBALS);
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
        // host-backed interface object with the constructable seeded constructor,
        // so `new document.defaultView.MutationObserver(cb)` works — in a real
        // window, window.X IS the constructor function X. A host-backed interface
        // crosses as EITHER a non-constructable object OR a callable-but-not-
        // constructable Constructor proxy (typeof "function"); a nested window
        // resolves `Event`/`DOMException`/… to the latter, so an interface name is
        // replaced unconditionally rather than only when it isn't already a
        // function — else `new cw.Event(...)` throws "not a constructor".
        if (current == null || interfaceNames.has(name)) {
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

  // Bind a bridged Ruby object to a JS global (the bridge's define_host_object).
  function defineGlobal(name, handle) {
    globalThis[name] = makeProxy(handle);
  }

  // Expose the seeded constructors on a secondary window — an iframe's
  // contentWindow — given its handle. The proxy is retained in a registry
  // because the constructors become own properties of its target: were it
  // collected, a later `iframe.contentWindow` would build a fresh,
  // constructor-less proxy.
  function exposeConstructorsOnSubWindow(handle) {
    const proxy = makeProxy(handle);
    (globalThis.__rbSubWindows ||= []).push(proxy);
    exposeConstructorsOnWindow(proxy);
  }

  // Legacy `window.event`: a live accessor on globalThis, so a bare `event`
  // identifier (and `globalThis.event`) resolves to the window's current event
  // during dispatch — `event.stopPropagation()` in a listener that takes no
  // parameter. It reads the live globalThis.window on each get, so it follows a
  // rebound window (a fresh document per WPT file in a reused VM).
  function defineLegacyEventAccessor() {
    Object.defineProperty(globalThis, "event", {
      configurable: true, enumerable: false,
      get() { const w = globalThis.window; return w ? w.event : undefined; },
    });
  }

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

  // Interface-specific lifetime-constant props (same contract as
  // CONST_NODE_PROPS, but names too generic to cache globally — `name` is
  // mutable on inputs, immutable on an Attr). Morph libraries iterate
  // el.attributes reading every Attr's name; caching it removes one crossing
  // per read after the first.
  const CONST_IFACE_PROPS = new Map([
    ["Attr", new Set(["name", "localName", "namespaceURI", "prefix", "specified"])],
  ]);

  // Interface-specific epoch-stable props (same contract as
  // STABLE_EPOCH_NODE_PROPS): an Attr's value changes only through a DOM
  // mutation (attr.value= / setAttribute), which bumps the epoch.
  const STABLE_EPOCH_IFACE_PROPS = new Map([
    ["Attr", new Set(["value"])],
  ]);

  // Props the host has declined to handle a write for, per interface: the
  // host's __js_set__ dispatch is a pure function of the wrapper class and
  // property name, so a declined prop never becomes host-handled later and
  // subsequent writes can stay JS-side expandos without crossing. Keyed by
  // interface (each proxy's handler grabs its own Set once, so the hot path
  // is a plain Set.has with no per-write string building), and capped —
  // frameworks write per-navigation-random keys (React's __reactFiber$<rand>)
  // that never recur, so on a long-lived VM the Set would otherwise grow
  // without bound. Clearing an overflowed Set only costs one re-decline
  // (the entry is a pure optimization). Event handler names (on*) are never
  // recorded — their handling depends on the VALUE, not just the name.
  const declinedByInterface = new Map();
  const DECLINED_PROPS_CAP = 1024;
  function declinedSetFor(ifaceName) {
    if (ifaceName == null) return null;
    let set = declinedByInterface.get(ifaceName);
    if (!set) { set = new Set(); declinedByInterface.set(ifaceName, set); }
    return set;
  }
  const isEventHandlerName = (prop) => typeof prop === "string" && /^on[a-z]/.test(prop);

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
    "childElementCount", "textContent", "isConnected",
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
  // The one place that knows which event methods can flip the canceled
  // state — the defaultPrevented shadow (dispatchEvent fast path) must be
  // dropped around every one of them.
  const CANCELED_STATE_METHODS = new Set([
    "preventDefault", "initEvent", "initCustomEvent", "initUIEvent",
    "initMouseEvent", "initKeyboardEvent",
  ]);

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
    // Factories and cloners: they mint DETACHED nodes and mutate no existing
    // node's attributes or tree relations, so no cache can go stale. (A
    // custom-element constructor running inside createElement/cloneNode can
    // mutate the DOM, but its writes go through proxies and bump then.)
    // React's commit calls createElement per node; without this every one
    // was a full invalidation.
    "createElement", "createElementNS", "createTextNode", "createComment",
    "createDocumentFragment", "createCDATASection", "createProcessingInstruction",
    "createAttribute", "createAttributeNS", "createEvent", "createRange",
    "createNodeIterator", "createTreeWalker", "cloneNode", "importNode",
  ]);

  // Everything about an interface that every proxy of it shares: its name and
  // prototype chain, its method-name set, and the traits the traps branch on.
  // Derived once per interface and memoized, where the handler used to be
  // handed them as positional arguments recomputed on every crossing.
  const shapeByInterface = new Map();
  function interfaceShape(desc) {
    const cached = (desc.name != null) ? shapeByInterface.get(desc.name) : undefined;
    if (cached) return cached;

    const methods = new Set(desc.methods);
    // The maplike iterator methods are served as live iterators from the
    // prototype (see ENTRIES_ITERABLES), so drop the Ruby array-returning
    // versions from the method set — otherwise `entries()` would return an
    // Array (no `.next()`) instead of an iterator.
    if (ENTRIES_ITERABLES.has(desc.name)) {
      for (const m of ["entries", "keys", "values"]) methods.delete(m);
    }
    const shape = {
      name: desc.name,
      chain: desc.chain,
      methods,
      arrayLike: ARRAY_LIKE_COLLECTIONS.has(desc.name),
      named: NAMED_PROP_COLLECTIONS.get(desc.name) || null,
      nodeChain: !!(desc.chain && desc.chain.indexOf("Node") !== -1),
      indexedSetter: INDEXED_SETTER_INTERFACES.has(desc.name),
      constIface: CONST_IFACE_PROPS.get(desc.name) || null,
      stableIface: STABLE_EPOCH_IFACE_PROPS.get(desc.name) || null,
      declinedProps: declinedSetFor(desc.name),
      fixedShape: FIXED_SHAPE_INTERFACES.has(desc.name),
      // The [LegacyUnforgeable] attributes this interface plants as own
      // accessors (name -> writable), so the set trap knows to run one rather
      // than cross, and which ones reject.
      unforgeableAttrs: unforgeableAttrsOf(desc.chain),
    };
    // An interface with no name is not a cache key: two unrelated objects would
    // otherwise share the first one's shape.
    if (desc.name != null) shapeByInterface.set(desc.name, shape);
    return shape;
  }

  // ===== Method stubs =====

  // A proxy's methods are built on first read and memoized per proxy, so that
  // `el.foo === el.foo`. Most of them are one of four generic shapes; the
  // handful that need more are the SPECIAL_METHOD_STUBS table below, which is
  // where a new special case goes rather than into the get trap.
  //
  // `ctx` is what a stub can need beyond its own name: the handle it calls on,
  // whether the object is a Node, its interface name (for the WebIDL arity)
  // and the proxy's epoch-cached attribute reader.

  // Potentially mutating: bump the epoch before (a reentrant callback during
  // the call must not read stale snapshots) and after (the call's own mutations
  // invalidate later reads).
  function mutatingStub(prop, ctx) {
    const { handle, ifaceName } = ctx;
    return (...args) => {
      bumpDomEpoch();
      try {
        return hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(args)), ifaceName);
      } finally {
        bumpDomEpoch();
      }
    };
  }

  function nonMutatingStub(prop, ctx) {
    const { handle, ifaceName } = ctx;
    return (...args) => hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(args)), ifaceName);
  }

  // Mutating AND a `(Node or DOMString)...` union: coerce each arg (non-proxy
  // -> ToString) before it crosses, so null/undefined/numbers become their text
  // nodes per WebIDL.
  function nodeOrStringStub(prop, ctx) {
    const { handle, ifaceName } = ctx;
    return (...args) => {
      const coerced = args.map(coerceNodeOrString);
      bumpDomEpoch();
      try {
        return hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(coerced)), ifaceName);
      } finally {
        bumpDomEpoch();
      }
    };
  }

  // Every method that can change the event's canceled state (preventDefault
  // sets it, the legacy init* reinitializers reset it) drops a fast-dispatch
  // defaultPrevented shadow first — the next read then reflects the live host
  // value. None of them can touch the DOM, so no epoch bump.
  function canceledStateStub(prop, ctx) {
    const { handle, ifaceName } = ctx;
    return function (...args) {
      try {
        if (this && typeof this === "object") delete this.defaultPrevented;
      } catch (e) { /* non-configurable shadow can't exist; ignore */ }
      return hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(args)), ifaceName);
    };
  }

  function listenerStub(prop, ctx) {
    const handle = ctx.handle;
    return (...args) => {
      if (args.length >= 3) args[2] = flattenListenerOptions(prop, args[2]);
      return hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(args)), ctx.ifaceName);
    };
  }

  // getAttribute / hasAttribute off the element's per-epoch attribute snapshot,
  // with no crossing. Only a Node has one; anything else takes the generic stub.
  function cachedAttrStub(prop, ctx) {
    if (!ctx.nodeChain) return null;

    const read = ctx.cachedAttrRead;
    return (name) => read(prop, name);
  }

  // setAttribute / removeAttribute: a mutating attribute op, and additionally
  // an on* attribute set or removed at runtime (re)compiles or clears the
  // inline event handler.
  function attrWriteStub(prop, ctx) {
    if (!ctx.nodeChain) return null;

    const handle = ctx.handle;
    return function (...args) {
      bumpDomEpoch();
      try {
        const r = hostCallResult(prop, __rb_host_call(handle, prop, dehydrateArgs(args)), ctx.ifaceName);
        const attr = String(args[0] == null ? "" : args[0]);
        if (/^on[a-z]/i.test(attr)) {
          wireInlineHandler(this, attr.toLowerCase(), prop === "removeAttribute" ? null : args[1]);
        }
        return r;
      } finally {
        bumpDomEpoch();
      }
    };
  }

  // dispatchEvent has three paths. A JS-side Event (docs/js-side-events-design.md)
  // whose type nobody listens for never leaves JS; one that is listened for
  // materializes a host twin for the dispatch and folds the result back. A host
  // Event proxy tries the unlistened-dispatch fast path
  // (docs/event-dispatch-fastpath.md), where one crossing both decides and
  // dispatches; everything else is the classic bump-and-call.
  function dispatchEventStub(prop, ctx) {
    const handle = ctx.handle;
    return function (ev) {
      const state = ev !== null && typeof ev === "object" ? ev[JS_EVENT] : undefined;
      if (state !== undefined) return dispatchJsEvent(handle, prop, this, ev, state);

      if (isProxy(ev) && typeof globalThis.__rb_host_dispatch_fast === "function") {
        const r = __rb_host_dispatch_fast(handle, ev[HKEY]);
        if (r && typeof r === "object" && r.fast === true) {
          try { ev.defaultPrevented = r.result !== true; } catch (e) { /* frozen ev */ }
          return r.result === true;
        }
      }
      // A re-dispatch must not read a stale shadow from an earlier fast
      // dispatch: the slow path defers to the live host value.
      try { if (isProxy(ev)) delete ev.defaultPrevented; } catch (e) { /* ignore */ }
      bumpDomEpoch();
      try {
        return rehydrate(__rb_host_call(handle, prop, dehydrateArgs([ev])));
      } finally {
        bumpDomEpoch();
      }
    };
  }

  // Dispatching a JS-side Event at a host target.
  function dispatchJsEvent(handle, prop, target, ev, state) {
    if (state.host) {
      throw new globalThis.DOMException("The event is already being dispatched.", "InvalidStateError");
    }
    // Unlistened namespaced type: dispatch entirely JS-side — the only
    // crossing is the type check itself.
    if (typeof globalThis.__rb_host_event_fast === "function" &&
        __rb_host_event_fast(state.type) === true) {
      state.target = target;
      // Dispatch unsets the stop-propagation flags on completion (DOM
      // §dispatch), even when nothing listened.
      state.stopped = false;
      return state.canceled !== true;
    }
    // Slow path: materialize the host twin (carrying over any pre-set
    // canceled/stopped state), register it so listeners receive THIS JS
    // object, dispatch, then fold the final state back and drop the twin.
    const init = { bubbles: state.bubbles, cancelable: state.cancelable, composed: state.composed };
    if (state.name === "CustomEvent") init.detail = state.detail;
    const twin = rehydrate(__rb_construct(state.name, dehydrateArgs([state.type, init])));
    if (state.canceled) twin.preventDefault();
    if (state.stopped) twin.stopPropagation();
    jsEventByHandle.set(twin[HKEY], ev);
    state.host = twin;
    bumpDomEpoch();
    try {
      const r = rehydrate(__rb_host_call(handle, prop, dehydrateArgs([twin])));
      // dispatchEvent returns !canceled — fold it back without re-reading the
      // twin's defaultPrevented.
      state.canceled = r !== true;
      return r;
    } finally {
      bumpDomEpoch();
      state.target = twin.target;
      // DOM §dispatch unsets the stop-propagation flags when the dispatch
      // completes; a reused event object must propagate again (the canceled
      // flag, by contrast, persists).
      state.stopped = false;
      jsEventByHandle.delete(twin[HKEY]);
      state.host = null;
    }
  }

  // crypto.getRandomValues(typedArray): the Web Crypto spec fills the caller's
  // typed array IN PLACE and returns it, so the type and identity survive — which
  // crossing to the host as a byte buffer would lose. It also rejects anything
  // that is not an integer typed array (Float arrays, DataView) with a
  // TypeMismatchError and an over-long buffer with a QuotaExceededError; the
  // host only supplies the random bytes.
  const INTEGER_TYPED_ARRAYS = [
    "Int8Array", "Int16Array", "Int32Array", "BigInt64Array", "Uint8Array",
    "Uint8ClampedArray", "Uint16Array", "Uint32Array", "BigUint64Array",
  ];
  const RANDOM_VALUES_MAX_BYTES = 65536;

  function isIntegerTypedArray(value) {
    if (typeof ArrayBuffer === "undefined" || !ArrayBuffer.isView(value)) return false;
    return INTEGER_TYPED_ARRAYS.some((name) => typeof globalThis[name] === "function" && value instanceof globalThis[name]);
  }

  function randomValuesStub(_prop, ctx) {
    const { handle } = ctx;
    return (array) => {
      if (!isIntegerTypedArray(array)) {
        throw makeHostError({name: "TypeMismatchError", message: "getRandomValues needs an integer typed array"});
      }
      const { byteLength } = array;
      if (byteLength > RANDOM_VALUES_MAX_BYTES) {
        throw makeHostError({name: "QuotaExceededError", message: "getRandomValues quota is 65536 bytes"});
      }
      const random = rehydrate(__rb_host_call(handle, "__internal_random_bytes__", dehydrateArgs([byteLength])));
      // Never hand back an array that was not filled: a caller would take its
      // zeros for random bytes.
      if (!(random instanceof Uint8Array) || random.length !== byteLength) {
        throw makeHostError({name: "OperationError", message: "the host supplied no random bytes"});
      }
      new Uint8Array(array.buffer, array.byteOffset, byteLength).set(random);
      return array;
    };
  }

  // Methods whose stub is more than the generic call for their class. A factory
  // may answer null — `getAttribute` is only special on a Node — and the
  // generic stub is used then.
  const SPECIAL_METHOD_STUBS = new Map([
    ["addEventListener", listenerStub],
    ["removeEventListener", listenerStub],
    ["dispatchEvent", dispatchEventStub],
    ["getAttribute", cachedAttrStub],
    ["hasAttribute", cachedAttrStub],
    ["setAttribute", attrWriteStub],
    ["removeAttribute", attrWriteStub],
    ["getRandomValues", randomValuesStub],
  ]);

  function makeMethodStub(prop, ctx) {
    const special = SPECIAL_METHOD_STUBS.get(prop);
    let fn = special ? special(prop, ctx) : null;
    if (!fn) {
      if (CANCELED_STATE_METHODS.has(prop)) fn = canceledStateStub(prop, ctx);
      else if (NON_MUTATING_METHODS.has(prop)) fn = nonMutatingStub(prop, ctx);
      else if (NODE_OR_STRING_METHODS.has(prop)) fn = nodeOrStringStub(prop, ctx);
      else fn = mutatingStub(prop, ctx);
    }
    withArity(fn, prop, ctx.ifaceName);
    return fn;
  }

  // ===== Named properties (WebIDL legacy platform objects) =====
  //
  // The live "supported property names" of a named getter, and the visibility
  // rule that decides whether one is reachable as a property. Both the traps
  // (via the per-proxy shorthands in makeHandler) and the set rules below ask
  // these, so they take the handle and the interface's named-props entry rather
  // than closing over a particular proxy.

  function namedKeysOf(handle, named) {
    if (!named) return [];
    const r = rehydrate(__rb_named_props(handle));
    return Array.isArray(r) ? r : [];
  }

  function isNamedKeyOf(handle, named, prop) {
    return !!named && typeof prop === "string" && namedKeysOf(handle, named).indexOf(prop) !== -1;
  }

  // WebIDL named-property visibility: a named property is EXPOSED (reachable via
  // property access / enumeration) only when it is not shadowed by an own
  // expando or — absent [LegacyOverrideBuiltIns] — a property anywhere on the
  // prototype chain. So `Storage.prototype.foo = x` hides the stored "foo" from
  // `storage.foo` while `storage.getItem("foo")` still returns it.
  function namedShadowedByProtoOf(named, t, prop) {
    // [LegacyOverrideBuiltIns]: named props are NOT shadowed by the prototype
    // chain (only by an own expando, which callers check separately).
    if (named && named.overrideBuiltins) return false;
    const proto = Object.getPrototypeOf(t);
    return proto != null && (prop in proto);
  }

  // ===== Writing to a host proxy =====
  //
  // A write is decided by the FIRST rule below that claims it, and that order IS
  // the algorithm: [LegacyUnforgeable] beats a prototype setter, which beats a
  // named collection's rejection, which beats the JS-expando fast path, and the
  // host is asked only once nothing JS-side owns the name. Written as a list,
  // the order is something you can read and reorder deliberately; written as a
  // run of `if`s, it was something you had to reconstruct from a comment.
  //
  // A rule declines by returning `undefined` ("not my case, ask the next one")
  // and claims the write by returning the boolean the trap answers with. They
  // share one argument order — (handle, shape, t, prop, value, receiver) — and
  // each declares only the prefix it uses. They are module-level functions, not
  // per-proxy closures, because every DOM node's proxy is pinned for the node's
  // lifetime: a rules array per handler would be a rules array per node.
  //
  // setSymbolKey runs first, so EVERY LATER RULE SEES A STRING KEY.

  // Pin the proxy whenever JS state lands on it, so the node's expandos outlive
  // GC of this particular proxy (see the `pinned` declaration).
  function pinIfProxy(handle, receiver) {
    if (proxyHandles.has(receiver)) pinned.set(handle, receiver);
  }

  // A symbol key names no DOM property — it is framework bookkeeping, and stays
  // on the target.
  function setSymbolKey(handle, shape, t, prop, value, receiver) {
    if (typeof prop !== "symbol") return undefined;
    t[prop] = value;
    pinIfProxy(handle, receiver);
    return true;
  }

  // `obj.__proto__ = v` reaches Object.prototype's accessor, whose job is to
  // call [[SetPrototypeOf]] and throw a TypeError when that answers false — and
  // QuickJS's does not throw, it ignores. Harmless where the prototype is
  // settable (nothing to report), but on a fixed shape (Location) the refusal is
  // the whole point, so raise it here.
  function setImmutablePrototype(handle, shape, t, prop, value, receiver) {
    if (!shape.fixedShape || prop !== "__proto__") return undefined;
    if (Reflect.setPrototypeOf(receiver, value)) return true;

    throw new TypeError("Cannot set the prototype of this object");
  }

  // A [LegacyUnforgeable] attribute is an OWN accessor on the target, and its
  // shared setter reads the handle off `this` — so run it with the PROXY as the
  // receiver rather than assigning into the bare target, which carries no
  // handle. A readonly one (`location.origin`) rejects.
  function setUnforgeableAttribute(handle, shape, t, prop, value, receiver) {
    const attrs = shape.unforgeableAttrs;
    if (attrs === null || !attrs.has(prop)) return undefined;
    if (!attrs.get(prop)) return false;

    Reflect.set(t, prop, value, receiver);
    return true;
  }

  // A writable named collection (Storage/DOMStringMap) routes every string
  // assignment through its named setter, which takes precedence over a prototype
  // accessor — so `storage.x = v` never invokes a `Storage.prototype` setter.
  // Other objects defer to a matching prototype setter (a framework's reactive
  // property, e.g. Lit) as usual.
  function setViaPrototypeSetter(handle, shape, t, prop, value, receiver) {
    if (shape.named && shape.named.writable) return undefined;
    if (!settersOf(Object.getPrototypeOf(t)).has(prop)) return undefined;

    Reflect.set(t, prop, value, receiver);
    return true;
  }

  // Legacy platform object with NO indexed setter: an array-index assignment
  // never becomes an expando — it is a no-op (sloppy) / TypeError (strict), so
  // the trap answers false. Objects WITH one (HTMLSelectElement /
  // HTMLOptionsCollection) decline here and reach the host, which runs the
  // WebIDL "set an indexed property" algorithm (add / replace / remove option).
  function rejectIndexedWrite(handle, shape, t, prop) {
    if (!shape.arrayLike || shape.indexedSetter || !isArrayIndex(prop)) return undefined;

    return false;
  }

  // A read-only named property (HTMLCollection / NamedNodeMap) rejects — unless
  // an own expando already shadows it, in which case that expando is what is
  // being written and a later rule handles it.
  function rejectNamedWrite(handle, shape, t, prop) {
    const named = shape.named;
    if (!named || named.writable || Object.hasOwn(t, prop)) return undefined;
    if (!isNamedKeyOf(handle, named, prop)) return undefined;

    return false;
  }

  // An existing JS expando, or a property the host has already declined once for
  // this interface: stays JS-side without asking the host again. Framework
  // bookkeeping (React's __reactFiber$ / __reactProps$) writes these on every
  // node of every commit — one crossing each before this. Event-handler names
  // and the global window keep crossing (their handling depends on the value and
  // on host state, not on the name alone), as do writable named collections.
  function setJsExpando(handle, shape, t, prop, value, receiver) {
    if ((shape.named && shape.named.writable) ||
        isEventHandlerName(prop) || isGlobalWindow(handle)) return undefined;
    const declined = shape.declinedProps;
    if (!Object.hasOwn(t, prop) && !(declined !== null && declined.has(prop))) return undefined;

    t[prop] = value;
    pinIfProxy(handle, receiver);
    return true;
  }

  // The global window: a write to a name the host doesn't already resolve
  // becomes a JS global (`window.X = …` ≡ `globalThis.X = …`), so window-attached
  // and globalThis-attached globals converge on ONE storage. A host-resolved
  // property (location, navigator, a Ruby-side stash, …) declines and routes to
  // the host. (globalThis is NOT this proxy's prototype, so the plain assignment
  // can't recurse back into the trap.)
  function setWindowGlobal(handle, shape, t, prop, value) {
    if (!isGlobalWindow(handle)) return undefined;
    // Event handler IDL attributes (onload, onresize, …) must reach the host so
    // it registers a listener that actually fires; they read back as null when
    // unset, so the null-means-unresolved test below would otherwise divert them
    // to a plain (never-firing) JS global.
    if (isEventHandlerName(prop)) return undefined;
    const cur = __rb_host_get(handle, prop);
    const absent = cur !== null && typeof cur === "object" && cur.__rb_absent === true;
    if (!absent && rehydrate(cur) !== null) return undefined;

    globalThis[prop] = value;
    return true;
  }

  // The rules that can CLAIM a write, in the order they are asked. A write no
  // rule claims is a host property write — setHostProperty, which always answers.
  const SET_RULES = [
    setSymbolKey,
    setImmutablePrototype,
    setUnforgeableAttribute,
    setViaPrototypeSetter,
    rejectIndexedWrite,
    rejectNamedWrite,
    setJsExpando,
    setWindowGlobal,
  ];

  // Ask the host to take the write, and keep it JS-side if it won't. The WebIDL
  // value coercions live here rather than in the rules above because they matter
  // only on the way across.
  function setHostProperty(handle, shape, t, prop, value, receiver) {
    // Legacy `returnValue = false` cancels an event host-side; drop a
    // fast-dispatch defaultPrevented shadow so the next read sees it. Gated on
    // preventDefault's presence — only events carry it.
    if (prop === "returnValue" && shape.methods.has("preventDefault") &&
        Object.hasOwn(t, "defaultPrevented")) {
      delete t.defaultPrevented;
    }
    // WebIDL [LegacyNullToEmptyString] DOMString setters coerce JS-side (null →
    // "", else ToString — so `innerHTML = 42` / `{toString…}` work and a toString
    // that throws propagates) before the value crosses into Ruby.
    if (nullToEmptyString(shape.name, prop)) value = value === null ? "" : String(value);
    // A writable named property (Storage/DOMStringMap) has a DOMString named
    // setter: ToString-coerce too, so `storage.x = 42` stores "42", `= null`
    // stores "null", and a `{toString}` object's throwing toString propagates.
    if (shape.named && shape.named.writable) value = String(value);
    if (hostSet(handle, prop, value)) return true;

    t[prop] = value;
    pinIfProxy(handle, receiver);
    rememberDecline(handle, shape, prop);
    return true;
  }

  // Remember a decline per (interface, prop): the host's set dispatch is a pure
  // function of the wrapper class and the property name, so a declined prop never
  // becomes host-handled later and subsequent writes can stay JS-side without
  // crossing. Capped — a page writes per-navigation-random keys that never recur,
  // so on a long-lived VM the Set would otherwise grow without bound, and
  // clearing an overflowed one costs a single re-decline.
  function rememberDecline(handle, shape, prop) {
    const declined = shape.declinedProps;
    if (declined === null || isEventHandlerName(prop) || isGlobalWindow(handle)) return;
    if (declined.size >= DECLINED_PROPS_CAP) declined.clear();
    declined.add(prop);
  }

  // The proxy handler for one host object: `handle` is the object, `shape` is
  // everything its interface decides (see interfaceShape) and `methodCache`
  // memoizes its method stubs. The per-interface traits used to arrive as eight
  // positional arguments, rebuilt on every crossing.
  function makeHandler(handle, shape, methodCache) {
    const { methods, arrayLike, named, nodeChain, fixedShape } = shape;
    // Per-interface, resolved when the shape was built: the const and
    // epoch-stable prop sets (Attr#name, Attr#value).
    const { constIface, stableIface } = shape;
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
    // This proxy's view of the shared named-property helpers (see namedKeysOf):
    // the live "supported property names", re-queried each call so they track
    // DOM mutations, and the visibility rule.
    const namedKeys = () => namedKeysOf(handle, named);
    const isIndexInRange = (prop) => arrayLike && isArrayIndex(prop) && Number(prop) < liveLength();
    const isNamedKey = (prop) => isNamedKeyOf(handle, named, prop);
    const namedShadowedByProto = (t, prop) => namedShadowedByProtoOf(named, t, prop);
    // What a method stub can need beyond its own name (see makeMethodStub).
    const stubContext = {
      handle, nodeChain, ifaceName: shape.name, cachedAttrRead,
    };
    // Names the page has deleted off the window. Interface constructors and
    // other JS globals are own properties of the window proxy target, but the
    // host also resolves them, so without a tombstone `delete window.Event`
    // would resurrect the host-backed constructor on the next read. Re-assigning
    // the name clears the tombstone. Only the global window is affected.
    const deletedGlobals = new Set();
    return {
      get(t, prop, receiver) {
        if (prop === HKEY) return handle;
        if (typeof prop === "symbol") return Reflect.get(t, prop, receiver);
        if (typeof prop === "string" && isGlobalWindow(handle) && deletedGlobals.has(prop)) return undefined;
        if (Object.hasOwn(t, prop)) return Reflect.get(t, prop, receiver);
        // [LegacyOverrideBuiltIns] (HTMLFormElement): a named control shadows the
        // prototype's methods AND accessors, so resolve it before either. An own
        // expando (checked above) still wins.
        if (named && named.overrideBuiltins && typeof prop === "string" && isNamedKey(prop)) {
          return rehydrate(__rb_host_get(handle, prop));
        }
        if (methods.has(prop)) {
          // A read-only collection operation resolves to the interface
          // prototype's function (so `coll.item === HTMLCollection.prototype.item`
          // and `.length` is the WebIDL arity). Data property on the proto chain,
          // so Reflect.get won't re-enter this trap.
          if ((arrayLike || named) && PROTO_RESOLVED_METHODS.has(prop)) {
            const protoFn = Reflect.get(t, prop, receiver);
            if (typeof protoFn === "function") return protoFn;
          }
          let fn = methodCache.get(prop);
          if (!fn) {
            fn = makeMethodStub(prop, stubContext);
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
        if ((nodeChain && STABLE_EPOCH_NODE_PROPS.has(prop)) ||
            (stableIface !== null && stableIface.has(prop))) {
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
        if (constCache !== null && !isAbsent &&
            (CONST_NODE_PROPS.has(prop) || (constIface !== null && constIface.has(prop))) &&
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
      // Each rule either claims the write or defers to the next; whatever none
      // of them claims is a host property write. See SET_RULES.
      set(t, prop, value, receiver) {
        if (typeof prop === "string" && deletedGlobals.has(prop)) deletedGlobals.delete(prop);
        for (let i = 0; i < SET_RULES.length; i++) {
          const answer = SET_RULES[i](handle, shape, t, prop, value, receiver);
          if (answer !== undefined) return answer;
        }
        return setHostProperty(handle, shape, t, prop, value, receiver);
      },
      // Array-like collections reflect their indices as own enumerable
      // properties so `hasOwnProperty(i)` / `Object.keys` / `{...spread}` see the
      // live children (testharness's assert_array_equals checks hasOwnProperty).
      // Named properties (HTMLCollection ids/names, dataset keys, attr names)
      // are reflected too — non-enumerable for [LegacyUnenumerableNamedProperties].
      getOwnPropertyDescriptor(t, prop) {
        if (typeof prop === "string" && isGlobalWindow(handle) && deletedGlobals.has(prop)) return undefined;
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
        if (typeof prop === "string" && deletedGlobals.has(prop)) deletedGlobals.delete(prop);
        // Cannot redefine a live indexed or read-only named property.
        if (arrayLike && isArrayIndex(prop)) return false;
        if (named && !named.writable && !Object.hasOwn(t, prop) && isNamedKey(prop)) return false;
        // A writable named collection (Storage/DOMStringMap) has a named setter:
        // `Object.defineProperty(storage, k, {value})` routes to it (ToString-
        // coerced) rather than planting a JS expando that the named getter can't
        // see. Only for a plain data descriptor targeting a non-own property.
        if (named && named.writable && typeof prop === "string" && !Object.hasOwn(t, prop) &&
            desc && !desc.get && !desc.set && ("value" in desc)) {
          hostSet(handle, prop, String(desc.value));
          return true;
        }
        return Reflect.defineProperty(t, prop, desc);
      },
      // HTML gives Location an immutable prototype and refuses to seal it, so a
      // page cannot change what `location` resolves to by changing the object's
      // shape. `Object.setPrototypeOf` / `Object.preventExtensions` throw a
      // TypeError on the refusal and the `Reflect` forms answer false, which is
      // the whole difference between the two spellings.
      //
      // SetImmutablePrototype, not "always false": asking for the prototype it
      // already has asks for nothing, and succeeds.
      setPrototypeOf(t, proto) {
        return fixedShape ? proto === Reflect.getPrototypeOf(t) : Reflect.setPrototypeOf(t, proto);
      },
      preventExtensions(t) {
        return fixedShape ? false : Reflect.preventExtensions(t);
      },
      deleteProperty(t, prop) {
        // The global window: deleting a JS global through the window drops it
        // from globalThis (the shared namespace) and tombstones the name, so the
        // host resolution in `get` cannot resurrect it.
        if (typeof prop !== "symbol" && isGlobalWindow(handle) && Object.hasOwn(globalThis, prop)) {
          const removed = delete globalThis[prop];
          if (removed) {
            deletedGlobals.add(prop);
            Reflect.deleteProperty(t, prop);
          }
          return removed;
        }
        if (typeof prop !== "symbol" && Object.hasOwn(t, prop)) return Reflect.deleteProperty(t, prop);
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
        if (typeof prop === "string" && isGlobalWindow(handle) && deletedGlobals.has(prop)) return false;
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
      // Trust the cache only while the handle still names an object of the same
      // interface (see proxyInterfaces): a recycled handle otherwise resurfaces
      // the previous object's proxy.
      if (existing && (iface == null || proxyInterfaces.get(existing) === iface)) return existing;
      if (existing) {
        cache.delete(handle);
        pinned.delete(handle);
        proxyHandles.delete(existing);
        proxyInterfaces.delete(existing);
      }
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
    // 2d: the method-name set and the trap traits are per-interface; reuse them
    // across every proxy of that type.
    const shape = interfaceShape(desc);
    const target = (desc.chain && desc.chain.length)
      ? Object.create(protoForChain(desc.chain, 0))
      : {};
    // [LegacyUnforgeable] attributes live as own (non-configurable) accessors on
    // the instance target — `getOwnPropertyDescriptor(event, "isTrusted")` then
    // resolves them. The get trap still returns the live host value (it reads the
    // own prop via Reflect.get, invoking this shared getter).
    if (desc.chain) {
      for (const iface of desc.chain) installUnforgeable(target, iface);
    }
    // 2c: memoize method functions per proxy so `el.foo === el.foo`.
    const isNode = shape.nodeChain;
    const p = new Proxy(target, makeHandler(handle, shape, new Map()));
    cache.set(handle, new WeakRef(p));
    proxyHandles.set(p, handle);
    proxyInterfaces.set(p, desc.name);
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
    // An iframe's contentWindow crosses as a NON-global Window proxy. Seed its
    // own constructor set (Event/DOMException/Range/… + JS builtins) the first
    // time it materializes, so a nested realm resolves
    // `iframe.contentWindow.DOMException` / cross-frame `instanceof` like a real
    // browser. The top window is seeded explicitly at install time — the
    // `globalThis.window` guard skips it (during its own creation the global
    // isn't assigned yet), and once it is, isGlobalWindow tells the two apart.
    if (desc.name === "Window" && globalThis.window && !isGlobalWindow(handle)) {
      try { exposeConstructorsOnWindow(p); } catch (e) { /* best effort */ }
    }
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

  // Ruby re-wrapped an element its definition now applies to and moved the
  // element's handle onto the new wrapper (HostBridge#upgrade_in_place). The
  // proxy a script already holds is upgraded where it stands, and recorded under
  // the new interface so a later crossing tagged with it keeps the same object.
  function upgradeInPlace(handle, name, iface) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const ref = cache.get(handle);
    const proxy = ref && ref.deref();
    if (!proxy) return;
    if (iface != null) proxyInterfaces.set(proxy, iface);
    upgradeElement(proxy, name);
  }

  // Ruby calls this when a registered custom element fires a lifecycle reaction.
  // makeProxy upgrades on first crossing, so the constructor has already run.
  function invokeLifecycle(handle, callback, args) {
    bumpDomEpoch(); // Ruby -> JS entry: see invokeCallback
    const p = makeProxy(handle);
    const fn = p[callback];
    if (typeof fn !== "function") {
      // HTML "enqueue a custom element callback reaction": without a
      // connectedMoveCallback, a move runs disconnectedCallback and then
      // connectedCallback in its place.
      if (callback === "connectedMoveCallback") {
        invokeLifecycle(handle, "disconnectedCallback", []);
        invokeLifecycle(handle, "connectedCallback", []);
      }
      return undefined;
    }
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
      // each must be undefined or a function. connectedMoveCallback is read here
      // like the rest, though Dommy's moveBefore does not enqueue custom element
      // reactions yet.
      const readCallback = (cb) => {
        const fn = proto[cb];
        if (fn !== undefined && typeof fn !== "function") {
          throw new TypeError("The " + cb + " callback is not a function");
        }
        return fn;
      };
      readCallback("connectedCallback");
      readCallback("disconnectedCallback");
      readCallback("connectedMoveCallback");
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
    // The engine's promise-rejection hook (see onPromiseRejection).
    onPromiseRejection,
    seedInterfaces, invokeLifecycle, upgradeInPlace, attachStatics, exposeConstructorsOnWindow,
    // Realm wiring the Ruby bridge drives, kept here rather than as JS built in
    // Ruby strings (see defineGlobal / defineLegacyEventAccessor).
    defineGlobal, exposeConstructorsOnSubWindow, defineLegacyEventAccessor, wireInlineHandlers,
    // wasm host bridge (handle-oriented access for a wasm guest)
    wasmGlobalRef, wasmEval, wasmGet, wasmSet, wasmCall, wasmApply, wasmNew,
    wasmTypeof, wasmToString, wasmStrictEqual, wasmIsNull, wasmInstanceof,
    wasmMakeCallback, wasmReleaseRef,
  };
})();
