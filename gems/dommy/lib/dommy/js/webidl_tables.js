// The WebIDL and HTML surface, as tables.
//
// These are the enumerations the specs themselves make: which interfaces have a
// value iterator or a named getter, what [Constant]s an interface object
// carries, which members go on which interface prototype and with what `length`,
// which attributes are [LegacyUnforgeable] or readonly, which operations return
// undefined, and which `on*` attributes are event handlers. They describe the
// platform, not Dommy's bridge — they change when a spec changes, whereas
// host_runtime.js changes when the bridge's machinery does, which is why they
// are a file of their own. test/support/webidl_audit.rb reads the [Constant]
// tables straight out of this file and checks them against the specs' own IDL.
//
// Bridge policy that merely happens to be a table — which properties are cheap
// enough to cache per DOM epoch, which methods skip the epoch bump — stays in
// host_runtime.js next to the machinery it tunes. So do the two- and three-line
// tables that only one function reads.
//
// Evaluated before host_runtime.js, which destructures this object.
globalThis.__rbIdl = (function () {
  "use strict";

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

  // Array-like collections whose IDL DOES declare `iterable<>`, and which
  // therefore carry keys() / values() / entries() / forEach() alongside
  // @@iterator. An indexed getter on its own gives an interface @@iterator and
  // nothing else, which is every other collection above — the list is short
  // because being iterable is the exception, not the rule.
  const PAIR_ITERABLE_COLLECTIONS = new Set(["NodeList", "DOMTokenList"]);

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
  // Each entry maps an attribute name to whether it has a setter — a readonly
  // one must not get one, and writability is a fact about the interface's
  // member, not about the name, so it travels with it here rather than in a
  // second table keyed by name alone.
  const RO = false;
  const RW = true;
  const UNFORGEABLE_ATTRS = {
    Event: { isTrusted: RO },
    // EVERY member of Location is [LegacyUnforgeable]. A page must not be able
    // to plant its own `href` on the object that says where it is, so the whole
    // interface is pinned to the instance rather than left on a prototype that
    // could be swapped or shadowed.
    Location: {
      href: RW, protocol: RW, host: RW, hostname: RW, port: RW,
      pathname: RW, search: RW, hash: RW,
      origin: RO, ancestorOrigins: RO,
    },
    // `document.location` is [LegacyUnforgeable] for the same reason, and
    // [PutForwards=href], so assigning to it navigates. Because the accessor
    // pair is shared per name, two Documents hand back the same getter and the
    // same setter, which is what document_location.html checks.
    Document: { location: RW },
  };
  // [LegacyUnforgeable] OPERATIONS are own properties of the instance too, and
  // enumerable — Location's stringifier `toString` among them, which is why
  // `getOwnPropertyDescriptor(location, "toString")` finds one.
  const UNFORGEABLE_METHODS = { Location: ["assign", "replace", "reload", "toString"] };
  // Own data properties HTML spells out for Location: nobody can replace
  // `valueOf` or install an `@@toPrimitive`, so `location` coerces through its
  // own toString and nothing else. valueOf is Object.prototype's — a Location
  // valueOf's to itself.
  const UNFORGEABLE_DATA = {
    Location: [["valueOf", Object.prototype.valueOf], [Symbol.toPrimitive, undefined]],
  };
  // Interfaces whose [[SetPrototypeOf]] and [[PreventExtensions]] return false:
  // a page can neither reparent a Location nor seal it, so its shape is as
  // fixed as its members.
  const FIXED_SHAPE_INTERFACES = new Set(["Location"]);

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

  // CSSOM rule-type [Constant]s. Dommy backs every rule with one class carrying
  // a numeric `type`, and library code reads these to branch on it
  // (`rule.type === CSSRule.STYLE_RULE`).
  const CSSRULE_CONSTANTS = {
    STYLE_RULE: 1, CHARSET_RULE: 2, IMPORT_RULE: 3, MEDIA_RULE: 4, FONT_FACE_RULE: 5,
    PAGE_RULE: 6, MARGIN_RULE: 9, NAMESPACE_RULE: 10
  };

  // EventSource / FileReader ready-state [Constant]s.
  const EVENTSOURCE_CONSTANTS = { CONNECTING: 0, OPEN: 1, CLOSED: 2 };
  const FILEREADER_CONSTANTS = { EMPTY: 0, LOADING: 1, DONE: 2 };

  // KeyboardEvent.location [Constant]s.
  const KEYBOARDEVENT_CONSTANTS = {
    DOM_KEY_LOCATION_STANDARD: 0x00, DOM_KEY_LOCATION_LEFT: 0x01,
    DOM_KEY_LOCATION_RIGHT: 0x02, DOM_KEY_LOCATION_NUMPAD: 0x03
  };

  // HTMLMediaElement networkState / readyState, and HTMLTrackElement readyState.
  const HTMLMEDIAELEMENT_CONSTANTS = {
    NETWORK_EMPTY: 0, NETWORK_IDLE: 1, NETWORK_LOADING: 2, NETWORK_NO_SOURCE: 3,
    HAVE_NOTHING: 0, HAVE_METADATA: 1, HAVE_CURRENT_DATA: 2, HAVE_FUTURE_DATA: 3,
    HAVE_ENOUGH_DATA: 4
  };
  const HTMLTRACKELEMENT_CONSTANTS = { NONE: 0, LOADING: 1, LOADED: 2, ERROR: 3 };

  // Interface name -> its [Constant]s (placed on both the interface object and
  // its prototype; instances inherit via the proxy get `prop in target` path).
  // Kept in step with the WebIDL by test/test_webidl_conformance.rb, which reads
  // this table and compares it against the specs' own `interfaces/*.idl`.
  const INTERFACE_CONSTANTS = {
    Node: NODE_CONSTANTS, Event: EVENT_CONSTANTS, NodeFilter: NODEFILTER_CONSTANTS,
    WebSocket: WEBSOCKET_CONSTANTS, Range: RANGE_CONSTANTS, XMLHttpRequest: XHR_CONSTANTS,
    DOMException: DOMEXCEPTION_CONSTANTS, CSSRule: CSSRULE_CONSTANTS,
    EventSource: EVENTSOURCE_CONSTANTS, FileReader: FILEREADER_CONSTANTS,
    KeyboardEvent: KEYBOARDEVENT_CONSTANTS,
    HTMLMediaElement: HTMLMEDIAELEMENT_CONSTANTS,
    HTMLTrackElement: HTMLTRACKELEMENT_CONSTANTS
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
    // AbstractRange's attributes live on its prototype, so a StaticRange and a
    // Range both reach them there; Range adds its operations.
    AbstractRange: { g: ["startContainer", "startOffset", "endContainer", "endOffset", "collapsed"] },
    Range: {
      m: ["setStart", "setEnd", "setStartBefore", "setStartAfter", "setEndBefore", "setEndAfter",
        "collapse", "selectNode", "selectNodeContents", "compareBoundaryPoints", "deleteContents",
        "extractContents", "cloneContents", "insertNode", "surroundContents", "cloneRange", "detach",
        "isPointInRange", "comparePoint", "intersectsNode", "getClientRects", "getBoundingClientRect",
        "createContextualFragment", "toString"],
      g: ["commonAncestorContainer"]
    },
    ReadableStream: { m: ["getReader", "cancel", "pipeTo", "pipeThrough", "tee"], g: ["locked"] },
    ReadableStreamDefaultReader: { m: ["read", "releaseLock", "cancel"], g: ["closed"] },
    ReadableStreamDefaultController: { m: ["enqueue", "close", "error"], g: ["desiredSize"] },
    WritableStream: { m: ["getWriter", "close", "abort"], g: ["locked"] },
    WritableStreamDefaultWriter: { m: ["write", "close", "abort", "releaseLock"], g: ["closed", "ready", "desiredSize"] },
    WritableStreamDefaultController: { m: ["error"] },
    TransformStream: { g: ["readable", "writable"] },
    TransformStreamDefaultController: { m: ["enqueue", "terminate", "error"], g: ["desiredSize"] },
    TextEncoderStream: { g: ["readable", "writable", "encoding"] },
    TextDecoderStream: { g: ["readable", "writable", "encoding", "fatal", "ignoreBOM"] },
    URLPattern: {
      m: ["test", "exec"],
      g: ["protocol", "username", "password", "hostname", "port", "pathname", "search", "hash",
        "hasRegExpGroups"]
    },
    Selection: {
      m: ["getRangeAt", "addRange", "removeRange", "removeAllRanges", "empty", "getComposedRanges",
        "collapse",
        "setPosition", "collapseToStart", "collapseToEnd", "extend", "setBaseAndExtent",
        "selectAllChildren", "deleteFromDocument", "containsNode", "toString"],
      g: ["anchorNode", "anchorOffset", "focusNode", "focusOffset", "isCollapsed",
        "rangeCount", "type", "direction"]
    },
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
        "prepend", "append", "replaceChildren", "moveBefore"],
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
      "prepend", "append", "replaceChildren", "moveBefore"] },
    ShadowRoot: { g: ["mode", "host", "delegatesFocus", "activeElement", "styleSheets"] },
    Document: {
      m: ["getElementById", "getElementsByTagName", "getElementsByTagNameNS",
        "getElementsByClassName", "getElementsByName", "createElement",
        "createElementNS", "createDocumentFragment", "createTextNode",
        "createCDATASection", "createComment", "createProcessingInstruction",
        "createAttribute", "createAttributeNS", "importNode", "adoptNode",
        "createEvent", "createRange", "createNodeIterator", "createTreeWalker",
        "querySelector", "querySelectorAll", "moveBefore"],
      g: ["documentElement", "doctype", "implementation", "compatMode",
        "characterSet", "contentType", "URL", "documentURI"],
      p: ["title"]
    },
    HTMLElement: {
      m: ["click", "focus", "blur"],
      p: ["title", "lang", "dir", "hidden", "innerText"]
    },
    // Event interfaces: seed the readonly attributes so they exist on the
    // prototype (WebIDL) — `("view" in ev)` / hasOwnProperty / getOwnPropertyDescriptor
    // resolve, and `Object.getPrototypeOf` walks the right chain. The get trap
    // still answers the value from the host (Ruby __js_get__), so these getters
    // only drive presence/enumeration, not the value.
    UIEvent: { g: ["view", "detail"] },
    MouseEvent: {
      g: ["screenX", "screenY", "clientX", "clientY", "ctrlKey", "shiftKey",
        "altKey", "metaKey", "button", "buttons", "relatedTarget"]
    },
    KeyboardEvent: {
      g: ["key", "code", "location", "ctrlKey", "shiftKey", "altKey", "metaKey",
        "repeat", "isComposing"]
    },
    WheelEvent: { g: ["deltaX", "deltaY", "deltaZ", "deltaMode"] },
    FocusEvent: { g: ["relatedTarget"] },
    CompositionEvent: { g: ["data"] },
    // Collection interfaces: only the READ-ONLY operations are seeded here, so
    // the get trap can resolve them straight to these prototype functions
    // (giving `coll.item === HTMLCollection.prototype.item`, per WebIDL). The
    // mutating ones (setNamedItem / removeNamedItem…) stay on the epoch-bumping
    // get-trap path, so they are deliberately absent.
    HTMLCollection: { m: ["item", "namedItem"] },
    NodeList: { m: ["item"] },
    NamedNodeMap: { m: ["item", "getNamedItem", "getNamedItemNS"] }
  };
  // WebIDL `[Unscopable]` members: each interface prototype that declares them
  // exposes a `@@unscopables` object so `with (element) { remove }` resolves to
  // the OUTER `remove` (per the ChildNode/ParentNode mixins), not the method.
  // The object has a null [[Prototype]] and the members map to `true`.
  const INTERFACE_UNSCOPABLES = {
    // ChildNode + ParentNode mixins, both included by Element.
    Element: ["after", "before", "remove", "replaceWith", "append", "prepend", "replaceChildren"],
    // ParentNode only.
    Document: ["append", "prepend", "replaceChildren"],
    DocumentFragment: ["append", "prepend", "replaceChildren"],
    // ChildNode only (Text / Comment / ProcessingInstruction / CDATASection).
    CharacterData: ["after", "before", "remove", "replaceWith"],
    // ChildNode only.
    DocumentType: ["after", "before", "remove", "replaceWith"]
  };
  // Read-only collection operations that resolve to their prototype function
  // (identity + arity) rather than a per-instance get-trap closure.
  const PROTO_RESOLVED_METHODS = new Set(["item", "namedItem", "getNamedItem", "getNamedItemNS"]);
  // WebIDL `(Node or DOMString)...` variadic operations: each argument is a
  // Node if it's one of our host proxies, otherwise it's ToString-coerced
  // (so `before(null)` inserts the text "null", `before(undefined)` -> "undefined",
  // `before(42)` -> "42"). Ruby can't tell null from undefined once marshaled, so
  // the union conversion must happen here, JS-side, before the args cross.
  const NODE_OR_STRING_METHODS = new Set([
    "before", "after", "replaceWith", "prepend", "append", "replaceChildren"
  ]);

  // The event handler CONTENT attributes HTML (with Pointer/Touch/Animation
  // Events) defines on elements. An `on*` attribute outside this set is not a
  // handler and must stay inert: `onreadystatechange` and `onvisibilitychange`
  // are IDL attributes of Document only, and `div.setAttribute("onfoobar", …)`
  // names no event handler at all.
  const ELEMENT_HANDLER_ATTRIBUTES = new Set([
    "onabort", "onauxclick", "onbeforeinput", "onbeforetoggle", "onblur", "oncancel",
    "oncanplay", "oncanplaythrough", "onchange", "onclick", "onclose", "oncommand",
    "oncontextlost", "oncontextmenu", "oncontextrestored", "oncopy", "oncuechange",
    "oncut", "ondblclick", "ondrag", "ondragend", "ondragenter", "ondragleave",
    "ondragover", "ondragstart", "ondrop", "ondurationchange", "onemptied", "onended",
    "onerror", "onfocus", "onfocusin", "onfocusout", "onformdata", "oninput",
    "oninvalid", "onkeydown", "onkeypress", "onkeyup", "onload", "onloadeddata",
    "onloadedmetadata", "onloadstart", "onmousedown", "onmouseenter", "onmouseleave",
    "onmousemove", "onmouseout", "onmouseover", "onmouseup", "onpaste", "onpause",
    "onplay", "onplaying", "onprogress", "onratechange", "onreset", "onresize",
    "onscroll", "onscrollend", "onsecuritypolicyviolation", "onseeked", "onseeking",
    "onselect", "onselectstart", "onslotchange", "onstalled", "onsubmit", "onsuspend",
    "ontimeupdate", "ontoggle", "onvolumechange", "onwaiting", "onwheel",
    "onanimationstart", "onanimationend", "onanimationiteration",
    "ongotpointercapture", "onlostpointercapture", "onpointercancel", "onpointerdown",
    "onpointerenter", "onpointerleave", "onpointermove", "onpointerout",
    "onpointerover", "onpointerrawupdate", "onpointerup",
    "ontouchcancel", "ontouchend", "ontouchmove", "ontouchstart",
  ]);

  // Window event handlers that `body` and `frameset` — and only those two —
  // additionally carry as content attributes, reflecting onto the Window.
  const WINDOW_REFLECTED_HANDLERS = new Set([
    "onafterprint", "onbeforeprint", "onbeforeunload", "onhashchange",
    "onlanguagechange", "onmessage", "onmessageerror", "onoffline", "ononline",
    "onpagehide", "onpageshow", "onpopstate", "onrejectionhandled", "onstorage",
    "onunhandledrejection", "onunload",
  ]);

  // On body/frameset, blur/error/focus/load/resize/scroll are the Window's
  // handlers too, so they reflect there like the rest of WINDOW_REFLECTED.
  const BODY_REFLECTED_HANDLERS = new Set([
    ...WINDOW_REFLECTED_HANDLERS,
    "onblur", "onerror", "onfocus", "onload", "onresize", "onscroll",
  ]);

  // WebIDL operation `length` = the count of required arguments (it stops at the
  // first optional or variadic one). Our stubs use rest params, so they report 0;
  // stamp the spec length where a WPT test — or a `.length`-branching helper like
  // pre-insertion-validation-hierarchy.js — reads it. Names absent here keep 0,
  // which is already correct for the all-optional / variadic operations
  // (before/after/append/prepend/getRootNode/cloneNode/normalize/…).
  const METHOD_ARITY = {
    isEqualNode: 1, isSameNode: 1, compareDocumentPosition: 1, contains: 1,
    lookupPrefix: 1, lookupNamespaceURI: 1, isDefaultNamespace: 1,
    insertBefore: 2, appendChild: 1, replaceChild: 2, removeChild: 1,
    addEventListener: 2, removeEventListener: 2, dispatchEvent: 1,
    getAttribute: 1, setAttribute: 2, removeAttribute: 1, hasAttribute: 1,
    getAttributeNS: 2, setAttributeNS: 3, removeAttributeNS: 2, hasAttributeNS: 2,
    toggleAttribute: 1, getAttributeNode: 1, getAttributeNodeNS: 2,
    setAttributeNode: 1, setAttributeNodeNS: 1, removeAttributeNode: 1,
    attachShadow: 1, closest: 1, matches: 1, webkitMatchesSelector: 1,
    getElementsByTagName: 1, getElementsByTagNameNS: 2, getElementsByClassName: 1,
    insertAdjacentElement: 2, insertAdjacentText: 2, insertAdjacentHTML: 2,
    querySelector: 1, querySelectorAll: 1,
    substringData: 2, appendData: 1, insertData: 2, deleteData: 2, replaceData: 3,
    splitText: 1,
    getElementById: 1, getElementsByName: 1, createElement: 1, createElementNS: 2,
    createTextNode: 1, createCDATASection: 1, createComment: 1,
    createProcessingInstruction: 2, createAttribute: 1, createAttributeNS: 2,
    importNode: 1, adoptNode: 1, createEvent: 1, createNodeIterator: 1, createTreeWalker: 1,
    item: 1, namedItem: 1, getNamedItem: 1, getNamedItemNS: 2,
    setNamedItem: 1, setNamedItemNS: 1, removeNamedItem: 1, removeNamedItemNS: 2,
    replace: 2, toggle: 1, supports: 1,
    // Range. `collapse(optional toStart)` stays 0; Selection overrides it below.
    setStart: 2, setEnd: 2, setStartBefore: 1, setStartAfter: 1, setEndBefore: 1, setEndAfter: 1,
    selectNode: 1, selectNodeContents: 1, compareBoundaryPoints: 2, insertNode: 1,
    surroundContents: 1, isPointInRange: 2, comparePoint: 2, intersectsNode: 1,
    createContextualFragment: 1,
    moveBefore: 2,
    // Selection. `collapse` depends on the interface; see INTERFACE_METHOD_ARITY.
    getRangeAt: 1, addRange: 1, removeRange: 1, setPosition: 1, extend: 1,
    setBaseAndExtent: 4, selectAllChildren: 1, containsNode: 1,
  };
  // An operation whose length depends on the interface declaring it. Stubs are
  // made per interface, so an entry here overrides the per-name table above.
  const INTERFACE_METHOD_ARITY = {
    Selection: { collapse: 1 }, // Range.collapse(optional toStart) stays 0
    // `replace` is three unrelated operations sharing a name: Location's takes
    // one required argument, DOMTokenList's takes two, and CSSStyleSheet's one.
    // `assign` likewise — Location's requires a URL, HTMLSlotElement's is
    // variadic — so neither can be answered by the per-name table.
    Location: { replace: 1, assign: 1 },
    CSSStyleSheet: { replace: 1 }
  };

  // Operations whose WebIDL return type is undefined, in every interface that
  // has them. A Ruby method returns nil for "nothing", which crosses as null;
  // for these the caller must see undefined (`el.setAttribute(...) === undefined`).
  // Names a stream or another interface gives a real return value (close,
  // abort, cancel, write, error, enqueue, toggle, reportValidity) stay out,
  // and so do the ones whose null is an answer: insertAdjacentElement is
  // Element?, removeProperty returns the removed value.
  const VOID_METHODS = new Set([
    "addEventListener", "removeEventListener", "setAttribute", "setAttributeNS", "removeAttribute",
    "removeAttributeNS", "append", "prepend", "before", "after", "remove", "replaceWith", "replaceChildren",
    "moveBefore", "normalize", "insertAdjacentText", "insertAdjacentHTML",
    "preventDefault", "stopPropagation", "stopImmediatePropagation", "initEvent", "initCustomEvent",
    "focus", "blur", "click", "select", "setCustomValidity", "stepUp", "stepDown", "setSelectionRange",
    "setRangeText", "scrollIntoView", "scroll", "scrollTo", "scrollBy", "setPointerCapture",
    "releasePointerCapture", "observe", "unobserve", "disconnect", "setStart", "setEnd", "setStartBefore",
    "setStartAfter", "setEndBefore", "setEndAfter", "selectNode", "selectNodeContents", "deleteContents",
    "insertNode", "surroundContents", "detach", "removeAllRanges", "addRange", "removeRange", "collapse",
    "setPosition", "collapseToStart", "collapseToEnd", "extend", "setBaseAndExtent", "selectAllChildren",
    "deleteFromDocument", "setRequestHeader", "overrideMimeType", "setProperty",
    "pushState", "replaceState", "setItem", "removeItem",
    // Every other operation the specs Dommy models declare as returning
    // `undefined`, taken from their IDL rather than added one bug at a time.
    // A name is here only when EVERY interface declaring it returns undefined;
    // the ones that disagree are in INTERFACE_VOID_METHODS below.
    "addColorStop", "alert", "appendData", "appendMedium", "arc", "arcTo",
    "assign", "beginPath", "bezierCurveTo", "cancelAnimationFrame", "clear", "clearData", "clearInterval",
    "clearRect", "clearTimeout", "clip", "closePath", "define", "delete",
    "deleteCaption", "deleteCell", "deleteData", "deleteMedium", "deleteRow", "deleteRule", "deleteTFoot",
    "deleteTHead", "drawFocusIfNeeded", "drawImage", "ellipse", "fill", "fillRect", "fillText",
    "go", "hidePopover", "initKeyboardEvent", "initMessageEvent", "initUIEvent", "insertData", "lineTo",
    "load", "moveTo", "pause", "postMessage", "putImageData", "quadraticCurveTo", "queueMicrotask",
    "rect", "removeRule", "replaceData", "replaceSync", "reportError", "requestSubmit", "reset",
    "resetTransform", "restore", "rotate", "roundRect", "save", "scale", "send",
    "set", "setData", "setLineDash", "setTransform", "show", "showModal", "showPopover",
    "sort", "stroke", "strokeRect", "strokeText", "submit", "terminate", "throwIfAborted",
    "toBlob", "transform", "translate", "upgrade", "writeln", "add",
    "readAsArrayBuffer", "readAsBinaryString", "readAsDataURL", "readAsText", "back", "forward", "reload",
    "start", "enqueue", "error", "releaseLock",
  ]);

  // Operations whose return type depends on the interface, so a table keyed by
  // name cannot answer for them: `replace` is undefined on Location but a
  // boolean on DOMTokenList and a Promise on CSSStyleSheet, and `open` is
  // undefined on XMLHttpRequest but a Document or a WindowProxy on the other
  // two. Same shape as INTERFACE_METHOD_ARITY, and for the same reason.
  const INTERFACE_VOID_METHODS = {
    Location: ["replace"],
    XMLHttpRequest: ["open", "abort"],
    // A stream's close / abort / write answer with a Promise; everywhere else
    // those names return nothing, which is most of the platform — a dialog, an
    // EventSource, a MessagePort, a BroadcastChannel, document.write.
    BroadcastChannel: ["close"],
    Document: ["close", "write", "writeln"],
    EventSource: ["close"],
    HTMLDialogElement: ["close"],
    MessagePort: ["close"],
    ReadableStreamDefaultController: ["close"],
    AbortController: ["abort"],
    FileReader: ["abort"]
  };

  // The engine's native globals that `window.X` must mirror exactly.
  const JS_GLOBALS = [
    "Object", "Array", "Function", "String", "Boolean", "Number", "BigInt",
    "Symbol", "Date", "RegExp", "Promise", "Map", "Set", "WeakMap", "WeakSet",
    "Error", "TypeError", "RangeError", "SyntaxError", "ReferenceError",
    "Proxy", "Reflect", "JSON", "Math", "console",
  ];

  return {
    ARRAY_LIKE_COLLECTIONS,
    INDEXED_SETTER_INTERFACES,
    ENTRIES_ITERABLES,
    PAIR_ITERABLE_COLLECTIONS,
    NAMED_PROP_COLLECTIONS,
    NULL_TO_EMPTY_STRING_SETTERS,
    FORM_VALUE_FIELDS,
    READONLY_ATTRS,
    UNFORGEABLE_ATTRS,
    UNFORGEABLE_METHODS,
    UNFORGEABLE_DATA,
    FIXED_SHAPE_INTERFACES,
    INTERFACE_CONSTANTS,
    INTERFACE_MEMBERS,
    INTERFACE_UNSCOPABLES,
    PROTO_RESOLVED_METHODS,
    NODE_OR_STRING_METHODS,
    ELEMENT_HANDLER_ATTRIBUTES,
    WINDOW_REFLECTED_HANDLERS,
    BODY_REFLECTED_HANDLERS,
    METHOD_ARITY,
    INTERFACE_METHOD_ARITY,
    VOID_METHODS,
    INTERFACE_VOID_METHODS,
    JS_GLOBALS,
  };
})();
