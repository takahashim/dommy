# Changelog

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
