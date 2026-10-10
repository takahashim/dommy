# Changelog

## Unreleased

### Added

- `Session#resize_viewport(width, height)` resizes the browser window: the current page gets a `resize` event and re-evaluated `@media`, and later pages open at that size (`viewport_size` reads it back).
- `Session#virtual_time`, `Session#next_timer_delay` (the virtual ms to the page's next timer, nil when none), `Session#completion_pending?` (a response or message another thread handed back awaits the next turn of the loop), `Session#fetch_in_flight?` (a fetch is still running on the `network_executor`) and `Session#open_connections?` (a WebSocket or EventSource of the page or one of its frames is open), for a host waiting on the virtual clock.

### Changed

- `Session#settle` settles the page's frames too: the ready work of every realm, going round again while one hands another work that is ready at once (a frame's `postMessage` to the page). An animation that requests frame after frame runs its next frame and lets `settle` return.
- With `javascript: true`, `click_button` and `click_link` fire the click at the page, so Turbo, a client-side router or any listener can take the submission or the navigation over; an un-prevented click submits or follows through the page. dommy-examples' signup browser specs build 19 pages' scripts instead of 35, because Turbo now keeps the page across its form submissions.
- Unloading a document closes the WebSockets and EventSources it opened, without waiting for their readers: the page's and its frames' when the page navigates away, a frame's when it navigates or its iframe is removed. A connection the app ended or dropped reports `closed?` too.
- `Session#advance_time` moves the clock of the page and of every frame together, and `Session#next_timer_delay` is the soonest timer among them.
- Navigating to a `text/plain`, CSS, JavaScript or JSON response shows it as a text document, a `<pre>` holding the body, so `session.text` is the body and `on_document_loaded` fires; other non-HTML responses still keep the previous document.

## 0.15.0 — 2026-10-04

### Added

- A session's runtimes preload a page's big ES modules as bytecode when `Dommy::Js::ModulePreload.enabled` is set, so with Turbo served as an ES module a page after the second boots in about 11 ms instead of 24 ms.

### Changed

- Requires dommy ~> 0.15.0.
- A transport reports to its `WebSocket` or `EventSource` through `__internal_transport_open__`, `__internal_transport_message__`, `__internal_transport_error__` and `__internal_transport_closed__`; the `__transport_*__` names are gone.
- The session's navigation hooks are named with the `__internal_` prefix (`__internal_enqueue_page_navigation__` and the like); a custom navigation delegate calling the old names has to follow.

## 0.14.0 — 2026-10-01

### Added

- A same-origin `new EventSource(url)` on a page connects to the Rack app in-process and delivers its `text/event-stream` response as `message` events. A cross-origin URL keeps the in-memory stub.
- `Session#execute_script(script, *args)` / `#evaluate_script(script, *args)` pass their arguments to the script, and raise when the JS runtime cannot.
- `NetworkBridge.install` takes `resources:`, `executor:` and `scheduler:`, and is the one way the session installs its fetch handler.

### Changed

- A form submission sends the body its `enctype` declares: a `text/plain` form sends plain text and a `multipart/form-data` form a multipart body even without a file, where both were sent urlencoded.
- URLs go through Dommy's WHATWG URL parser rather than stdlib `URI`. `Dommy::Rack::Url` is rebuilt on it and loses its `URI` helpers (`encode_iri`, `http_host`, `origin` and the rest).
- `Dommy::Rack.visible?` is the one public visibility check; `hidden_node?` and `hidden_by_closed_details?` are private.

### Fixed

- A GET form with no entries still ends its URL in `?`, as a browser's does.
- A multipart part's name or filename percent-encodes CR and LF instead of dropping them, and a filename with a null byte no longer raises.

## 0.13.0 — 2026-09-23

### Added

- `Dommy::Rack::Session.new(app, strict_js_errors: true)` fails on JavaScript the page left unhandled, at the next point the page was allowed to run, so the failure lands on the line that caused it. Off by default.
- `Session#allow_js_errors { ... }` suppresses that failure for a block.

### Changed

- `js_errors` holds only what the page left unhandled: an error it cancels in `window.onerror` or in an `unhandledrejection` listener never reaches the log.
- The errors live in a shared `Dommy::Js::ErrorLog`, so an error the outgoing page left unreported survives the clear that navigation performs.

## 0.12.0 — 2026-09-22

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.12.0.
No functional changes to dommy-rack itself.

## 0.11.0 — 2026-09-11

### Added
- `Session#dialog_handler=` — answer the page's `alert` / `confirm` / `prompt`. The handler stays installed across navigations, so it also answers dialogs on pages loaded later.
- Traced requests now carry spans from inside the app (controller, SQL, render, and the jobs and mails a request triggers), flushed with the request they belong to. See dommy-rails for the Rails-side instrumentation.

### Fixed
- A request whose app raises still closes its trace bracket, so the trace ends with the failure instead of an open request.
- A subresource fetch made while a request is in flight keeps its own spans rather than attaching them to the outer request.
- SQL bind values, when enabled, are masked through the trace's own sensitive-key filter — the same one that masks form params.
- A snapshot's content is stored before its artifact event is written, so a trace read back straight away is complete.

## 0.10.0 — 2026-07-13

### Added
- **In-process WebSockets:** a same-origin `new WebSocket(url)` on a page connects to the Rack app itself over a real RFC 6455 handshake, so ActionCable's full stack (cookie auth, origin check, cable event loop) runs unmodified and Turbo Streams broadcasts work in tests. Cross-origin URLs keep the in-memory stub.
- **Joint session/window history:** same-document (`pushState`) navigations appear in the session history and `current_url`, and `Session#back` / `#forward` traverse them on the live page (Turbo Drive's restoration path) while document boundaries still re-request — matching a browser tab's single history list. JS-initiated traversal (`history.back()`) stays in sync.
- `Session#dispose` — full teardown (JS runtimes plus live WebSocket transports); `#dispose_js` remains JS-only.

### Fixed
- Only `BUTTON` / `INPUT` elements are treated as submit buttons.

## 0.9.0 — 2026-06-22

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.9.0.
Unlike previous releases, 0.9.0 carries real dommy-rack changes — driven by the
new JS runtime, async subresource fetching, and the integrated trace.

### Added
- **Trace / observability:** a structured event timeline for `Dommy::Rack::Session`, emitted as NDJSON, with extracted DOM-mutation / param-filter views and DOM snapshots.
- **Backend-agnostic `SessionRuntime`** that wires a JS runtime to a session (passing the session executor and window scheduler).
- **Cookie persistence:** `Session#export_cookies` / `#import_cookies` (backed by `CookieJar#export` / `#import!`), preserving host-only scoping across a JSON round-trip so an embedder can persist a login across restarts.
- **Subresource fetching & policy:**
  - Off-thread subresource fetch via an injected executor (`network_executor:`), with observation posted back through the scheduler inbox; the synchronous default is unchanged. `external_network_pending?` supports async-load run loops.
  - An opt-in cross-origin subresource allowlist on `Session`, plus an `:open` cross-origin subresource policy.
  - An embedder `subresource_host_blocker` denylist hook, consulted before any fetch (even in `:open` mode); denied hosts are recorded in a distinct dropped bucket, never prompted.
  - Concurrent prewarming of `<script src>` bundles before boot (gated on browser mode).
- **CSS resources:** external `<link rel=stylesheet>` CSS is fetched and applied on navigation, and `@import` URLs are resolved through the app.
- A thread-safe `CookieJar`; `HttpExchange` extracted as the per-request primitive.

### Fixed
- `js_errors` and `console` are cleared on page load (a browser's console clears on navigation).
- GET/HEAD navigation params are folded into the URL query, so `current_url` reflects a submitted GET form.
- Non-ASCII (IRI) URLs are percent-encoded before parsing.

## 0.8.0 — 2026-05-31

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.8.0.
No functional changes to dommy-rack itself.

## 0.7.0 — 2026-05-30

Initial release.

Versioned in lockstep with the [`dommy`](https://github.com/takahashim/dommy)
gem. dommy-rack lets a Rack application (including Rails) be visited and
manipulated as a `Dommy::Document` without launching a real browser, providing a
small, synchronous, browser-like session API with navigation, cookies,
redirects, link clicking, and form submission.
