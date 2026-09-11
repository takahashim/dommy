# Changelog

## 0.11.0 — 2026-09-11

### Added
- **Rails-internals spans in a trace.** A traced request no longer stops at the Rack boundary: controller action, SQL queries, view rendering, and any Active Job enqueue/perform or Action Mailer delivery it triggers appear inside it. `Dommy::Rails::TraceInstrumentation.install!(binds: true)` opts into SQL bind values, masked like form params.
- The instrumentation installs itself when a test boots its browser — no `rails_helper` line to add.
- **A failed browser spec leaves a trace bundle.** The failure output names the bundle — `tmp/dommy/failures/<example>/`, holding the page HTML, the trace and its artifacts — and the `dommylizer` command that opens it. One directory per example, so a re-run overwrites rather than piles up, and a failure while saving never masks the real one.

## 0.10.0 — 2026-07-13

### Changed
- The browser-spec teardown disposes the whole session (`dispose`), not just the JS runtime, so WebSocket transports opened by a spec are closed too.

### Build
- `bundler/gem_tasks` is loaded in the Rakefile so `rake release` works.

## 0.9.0 — 2026-06-22

Initial release.

Versioned in lockstep with the [`dommy`](https://github.com/takahashim/dommy)
gem. dommy-rails adds Rails-specific DOM testing helpers — matchers and
assertions for request, view, component, and mailer specs — on top of dommy and
dommy-rack, without launching a real browser.

### Added
- Rails form understanding: detects Rails forms, the `_method` override, and CSRF tokens.
- Turbo Stream and `<turbo-frame>` matchers (parse and assert responses / frame contents).
- Stimulus attribute checks (`data-controller`, `data-action`, `data-target`, `data-*-value`).
- HTML quality linting matchers.
- Role-based matchers (`have_role`) and a Playwright-style `match_aria_snapshot` matcher.
- `type: :browser` spec auto-wiring with a `Rails::BrowserSpec` helper, enabling the JS runtime via the session `javascript:` option.
