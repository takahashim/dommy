# Changelog

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
