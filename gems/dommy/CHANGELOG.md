# Changelog

## 0.8.1 — 2026-05-31

### Changed

- Declare `nokogiri` (`~> 1.19`) as a runtime dependency so the default backend is installed automatically; the `1.19` floor pulls in recent security fixes. Nokolexbor remains an opt-in alternative via `Dommy::Backend.use(:nokolexbor)`.

## 0.8.0 — 2026-05-31

A large WHATWG-conformance pass, focused on the Fetch surface, DOM traversal /
collections, selectors, encoding, and events.

### Added

#### Fetch — Response
- `new Response(body, init)` constructor, plus static `Response.json(data, init)`, `Response.redirect(url, status)`, and `Response.error()`
- `Response.type` (`"default"` / `"error"` / `"basic"`)
- `Response.body` is now a `ReadableStream` (or `null`); `Response.bodyUsed` tracks single consumption, and `text()` / `json()` / `arrayBuffer()` / `blob()` reject once the body has been read
- `Response.formData()` — parses an `application/x-www-form-urlencoded` or `multipart/form-data` body into a `FormData`
- Body extraction: a `Blob` / `File`, `URLSearchParams`, `FormData`, or `ArrayBuffer` / typed-array body is serialized to bytes with the matching default `Content-Type`

#### Fetch — Headers (WHATWG rewrite)
- Header names are stored lowercased; `keys()` / `values()` / `entries()` / `forEach()` iterate sorted, combining duplicate values with `", "`
- `Set-Cookie` is kept separate (never combined) and exposed via `getSetCookie()`
- Header name (token) and value (no NUL/CR/LF, whitespace-trimmed) validation, raising `TypeError`
- `new Headers(init)` accepts a record, a sequence of `[name, value]` pairs, or another `Headers`
- An immutable guard on the headers of `Response.error()` / `Response.redirect()`

#### Blob
- `Blob.text()` and `Blob.arrayBuffer()` now return `Promise`s (their spec return types)

#### DOM — Node & Document
- `Node#contains`, `isEqualNode`, `isSameNode`, `getRootNode`, `compareDocumentPosition`, and `lookupNamespaceURI` / `lookupPrefix` / `isDefaultNamespace`
- `DocumentType`, `ProcessingInstruction`, `CDATASection`, and `DOMImplementation` document factories
- `document.readyState` / `visibilityState` / `hidden` / `hasFocus()` and other document state getters; virtual `window` scroll properties

#### DOM — Traversal & collections
- `TreeWalker` and `NodeIterator` (`whatToShow`, `NodeFilter`, live-removal handling)
- `HTMLCollection`, `DOMStringMap`, and `NamedNodeMap` as WebIDL legacy platform objects (indexed + named properties); generalized `DOMTokenList`
- WICG `Observable` API (`Observable`, `Subscriber`, operators, `EventTarget.when`)

#### DOM — Selectors, parsing, encoding
- A CSS Selectors Level 4 grammar validator (invalid selectors raise a `SyntaxError`); `:scope`, `closest`
- `insertAdjacentHTML`, `outerHTML`, and XML parse/serialize via `DOMParser` / `XMLSerializer`
- `TextEncoder` / `TextDecoder` with typed-array marshalling, a WHATWG UTF-8 decoder, and `encodeInto`

#### Events, history, abort, ARIA
- WHATWG event propagation; a spec-compliant `WebSocket` with `MessageEvent` / `CloseEvent`; `PopStateEvent`
- `History` back/forward state restoration; a `SecurityError` for cross-origin `pushState` / `replaceState`
- `AbortController` / `AbortSignal` (`reason`, `timeout`, `throwIfAborted`)
- ARIA attribute reflection (`ariaXxx` ↔ `aria-xxx`) and element reflection

### Changed

- **Breaking:** `Response#arrayBuffer`, `Blob#arrayBuffer`, `FileReader#readAsArrayBuffer`, `XHR` `responseType: "arraybuffer"`, and `SubtleCrypto.digest` now resolve to a real `ArrayBuffer` — 0.7.0 had changed these to a byte `Array`.
- **Breaking:** `Headers` iteration is now lowercased and sorted (was Title-Case in insertion order).
- A `Response` `statusText` is validated against the reason-phrase grammar, and a null-body status (204/205/304) constructed with a body raises a `TypeError`.
- Requires Ruby >= 3.2.

### Fixed

- `MutationObserver` delivers records on the microtask queue and handles CharacterData / move records; `observe()` validates its options
- The URL parser throws a `TypeError` on parse failure and tolerates lone surrogates in JSON bodies
- `TextDecoder` strips a streaming BOM at the code-point level

## 0.7.0 — 2026-05-29

### Added

#### Queries & serialization
- XPath queries and document serialization helpers
- `:disabled` / `:enabled` / `:checked` CSS pseudo-classes in selector queries

#### URL
- WHATWG `URL.parse` / `URL.canParse` static methods

#### Document
- `document.origin` / `document.contentType`; `Location` origin now updates on absolute-URL navigation

#### FormData
- `multipart/form-data` encoding

#### CharacterData
- `ChildNode` mixin methods (`before` / `after` / `replaceWith` / `remove`) on `CharacterDataNode`

### Fixed

- `Headers#has` is now case-insensitive
- `Headers#forEach` passes the `Headers` object as the third callback argument
- `History.pushState` / `replaceState` now structured-clone the state argument
- `XHR.abort()` is a no-op when `OPENED` and the send() flag is unset
- `Event` dispatch resets `currentTarget` / `eventPhase` to their defaults afterward
- `Document.adoptNode` preserves node identity across documents
- `MutationObserver.observe()` replaces options on re-observation
- `CharacterDataNode#remove` and `Element#textContent=` now notify `MutationObserver`

### Changed

- **Breaking:** `Response#arrayBuffer` / `XHR` `responseType: "arraybuffer"` now resolve to a byte array (`Array<Integer>`), and `Response#blob` / `XHR` `responseType: "blob"` now resolve to a real `Dommy::Blob` (MIME type taken from the `Content-Type` header) — previously both returned the raw body string. Aligns with `FileReader` / `Blob`.
- Removed serialization from `FormData`
- Standardized gem-internal method naming conventions (`internal_` / `__test_` prefixes, JS-bridge dunder methods renamed)
- Added `__js_method_names__` to expose JS-bridge callable methods

## 0.6.0 — 2026-05-22

### Added

#### Layout-adjacent stubs
- `element.scrollIntoView` / `scrollTo` / `scrollBy` / `scroll` (no-op; calls recorded via `element.__scroll_log__` for test assertions)
- `element.scrollTop` / `scrollLeft` / `scrollWidth` / `scrollHeight` / `clientWidth` / `clientHeight` / `offsetWidth` / `offsetHeight` etc. — return 0
- `element.getClientRects` returns `[]`
- `window.getComputedStyle(el)` returns the element's inline `StyleDeclaration`

#### Popover API
- `element.showPopover` / `hidePopover` / `togglePopover`
- `popover` attribute, `beforetoggle` / `toggle` event firing with `{oldState, newState}` detail

#### Fullscreen API
- `element.requestFullscreen` / `document.exitFullscreen` / `document.fullscreenElement` / `document.fullscreenEnabled`
- `fullscreenchange` event

#### URLPattern
- `Dommy::URLPattern` (`/users/:id`, `/docs/*`, `:version+` modifier, etc.) — per-component pattern matching with named capture groups

#### View Transitions API
- `document.startViewTransition(callback)` returns a `ViewTransition` with all promises pre-resolved

#### Navigator extras
- `navigator.locks.request(name, callback)` / `query()` (Web Locks API)
- `navigator.storage.estimate()` / `persist()` / `persisted()` (StorageManager)

#### Crypto
- `crypto.subtle.encrypt` / `decrypt` (AES-GCM 128/256, with `additionalData` and `tagLength` options)

#### Original 0.6.0 additions:

#### SVG
- `Dommy::SVGElement` base + ~63 specialized subclasses covering shapes (`circle`/`rect`/`ellipse`/`line`/`polygon`/`polyline`/`path`), structure (`g`/`defs`/`symbol`/`use`/`image`/`foreignObject`), gradients (`linearGradient`/`radialGradient`/`stop`), filters (full set of standard primitives: Gaussian blur, offset, blend, color matrix, flood, composite, merge, component transfer, tile, morphology, image, drop shadow, turbulence, displacement map, convolve matrix, diffuse / specular lighting + light sources), marker / mask / pattern / clipPath, `<a>` / `<textPath>` / `<view>` / `<switch>` / `<metadata>`, and SMIL animation (`<animate>` / `<animateTransform>` / `<animateMotion>` / `<set>` / `<mpath>` / `<discard>`)
- Namespace-aware element dispatch — `<title>` inside `<head>` stays `HTMLTitleElement`, inside `<svg>` becomes `SVGTitleElement`
- Case-sensitive attribute round-trip for SVG (`viewBox`, `preserveAspectRatio`, etc.)

#### Web Animations API
- `Dommy::Animation` / `Dommy::KeyframeEffect` with full state machine (`idle` / `running` / `paused` / `finished`)
- `Element#animate(keyframes, options)` and `Element#get_animations`
- Auto-finish via scheduler (`advance_time`) and Promise integration (`animation.finished` / `animation.ready`)

#### Range / Selection
- `Dommy::Range` (boundary points, `compareBoundaryPoints`, `extractContents` / `cloneContents` / `surroundContents` / `deleteContents`, `intersectsNode` / `containsNode`, `toString`)
- `Dommy::Selection` (`document.get_selection`, `addRange`, `collapse`, `selectAllChildren`)
- Layout-dependent geometry returns zeroed rects

#### URL parsing (WHATWG-leaning)
- Unified `Dommy::URL` (the old `Dommy::Url` is removed)
- Input preprocessing: leading / trailing C0+space strip, embedded tab/LF/CR removal, special-scheme backslash → forward slash, percent-encoding of unsafe chars in path / query / fragment, `./` and `../` resolution, empty path → `/` for special schemes
- IPv4 number forms (`http://0x7f.1/`, `http://0177.0.0.1/`, `http://2130706433/`) normalize to dotted-decimal
- ws/wss default port stripping (`ws://h/` from `ws://h:80/`)
- `origin` follows the spec: tuple for http(s) / ws(s) / ftp, `"null"` for file / data / javascript, inner-URL origin for `blob:`
- Opaque-scheme body preservation (`javascript:alert(1)` keeps `alert(1)`, `mailto:` / `data:` / `tel:` / `blob:`)
- `url.search` exposes the raw query (preserves `%20`, stray `?`); `searchParams.toString()` still uses form-encoding (`+` for space)
- `hostname=` setter Punycode-encodes non-ASCII

#### IDNA (WHATWG complete)
- RFC 3492 Punycode encoder / decoder (`Dommy::Internal::Punycode`)
- UTS #46 IDNA ToASCII / ToUnicode (`Dommy::Internal::IDNA`) with WHATWG parameters (`UseSTD3ASCIIRules = false`, nontransitional)
- NFC normalization, Unicode case folding, UTS #46 mapping table, disallowed-character rejection
- RFC 5893 Bidi rules (all 6)
- RFC 5892 ContextJ (ZWJ / ZWNJ with Virama lookup)
- RFC 5892 ContextO (middle dot / Greek lower numeral sign / Hebrew geresh & gershayim / Katakana middle dot / mixed Arabic-Indic digits)
- Hyphen constraints, label-length cap (63 octets), domain-length cap (253 octets), leading combining mark rejection
- A-label / U-label validity (round-trip check, no-empty-intermediate, decoded U-label re-validation)
- Unicode 16.0 tables vendored under `vendor/unicode/`, regenerated via `script/build_idna_tables.rb`

#### Extended events
- `InputEvent` / `PointerEvent` / `ProgressEvent` / `DragEvent`
- `Touch` / `TouchList` / `TouchEvent` / `ClipboardEvent`
- `CompositionEvent` (IME) / `WheelEvent` (with `DOM_DELTA_*` constants)
- `FocusEvent` (`relatedTarget`) / `BeforeUnloadEvent` (`returnValue`)
- `MessageEvent` / `CloseEvent` / `CookieChangeEvent` / `MediaQueryListEvent`

#### Network / IO
- `XMLHttpRequest` (sync + async, full state machine, `responseType` decoding incl. JSON, shares `__fetchy_stub__` with `fetch`)
- `WebSocket` (test seams: `__simulate_open__` / `__simulate_message__` / `__simulate_close__` / `__simulate_error__`)
- `EventSource` (Server-Sent Events, `__simulate_message__(data, event: "...")`)
- `FileReader` (`readAsText` / `readAsDataURL` / `readAsArrayBuffer` / `readAsBinaryString`)
- `Streams` API: `ReadableStream` / `WritableStream` / `TransformStream`
- `TextEncoderStream` / `TextDecoderStream`
- `CompressionStream` / `DecompressionStream` (gzip / deflate / deflate-raw via Ruby `Zlib`)

#### Messaging
- `MessageChannel` / `MessagePort` (entangled ports with automatic `structuredClone` on transfer)
- `BroadcastChannel` (same-Window pub/sub)
- `Worker` (inline-emulated; test seams `__on_message__` / `__post_to_main__`)

#### Crypto
- `Dommy::Crypto` — `randomUUID` + `getRandomValues` (already in 0.5.0)
- `crypto.subtle.digest` (SHA-1 / SHA-256 / SHA-384 / SHA-512, RFC vectors verified)
- `crypto.subtle.generateKey` / `importKey` / `sign` / `verify` (HMAC, via OpenSSL)
- `CryptoKey` opaque handle

#### Storage / Cookies
- `cookieStore.get/getAll/set/delete` + `change` event (async Cookie Store API, backed by the same jar `document.cookie` uses)

#### Observers
- `IntersectionObserver` / `ResizeObserver` / `PerformanceObserver` (test-driven via `__trigger__(entries)`)

#### Navigator
- `navigator.geolocation` (`__set_position__` / `__set_error__` test seams)
- `navigator.share(data)` / `canShare(data)` (records last shared payload)
- `navigator.vibrate(pattern)` (records pattern log)
- `navigator.wakeLock.request(type)` → `WakeLockSentinel`
- `navigator.getBattery()` → `BatteryManager`

#### Scheduling / Performance
- `window.matchMedia(query)` → `MediaQueryList` (`__set_matches__` flips and fires `change`)
- `requestIdleCallback` / `cancelIdleCallback`
- `structuredClone` (global)
- `performance.mark` / `measure` / `getEntriesByName` / `getEntriesByType` / `clearMarks` / `clearMeasures`

#### Misc
- `Notification` with class-level `__set_permission__`
- `TextEncoder` / `TextDecoder` (UTF-8 / UTF-16 / ISO-8859-1)
- `Dommy.structured_clone` deep clone for primitives, Array, Hash, Set, DOM nodes (via `cloneNode`)

### Changed

- File renames to match class names: `world.rb` → `window.rb`, `observer.rb` → `mutation_observer.rb`
- File splits: `router.rb` → `location.rb` + `history.rb`, `observers.rb` → `intersection_observer.rb` + `resize_observer.rb` + `performance_observer.rb`
- `Internal::ObservableCallback` mixin shared across the three observer classes
- `Internal::RangeTextSerializer` collaborator extracted from `Range#to_s`
- `Range#compare_points` split into three topology-case helpers (`compare_offset_to_branch` / `compare_branch_to_offset` / `compare_via_lca`)

### Fixed

- `Dommy::URL.new("javascript:alert(1)").href` now returns `"javascript:alert(1)"` (previously dropped the body)
- `url.search` no longer round-trips through URLSearchParams (preserves `%20`, stray `?`)
- `Range#common_ancestor_container` now finds the deepest common ancestor
- `Internal::DomMatching` `when Range` now correctly references Ruby's `::Range` instead of `Dommy::Range`

## 0.5.0 — 2026-05-21

Initial release.
