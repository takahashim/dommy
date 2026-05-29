# Changelog

## 0.7.0 — 2026-05-30

Initial release.

Versioned in lockstep with the [`dommy`](https://github.com/takahashim/dommy)
gem. capybara-dommy is a Capybara driver backed by `dommy` and `dommy-rack`. It
drives Rack/Rails apps through the Capybara DSL without a real browser or
JavaScript, keeping the page as a `Dommy::Document` (RackTest-like, with
HTML-level visibility).
