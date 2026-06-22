# Changelog

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
