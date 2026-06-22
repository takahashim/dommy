# Changelog

## 0.9.0 — 2026-06-22

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.9.0.
No functional changes to capybara-dommy itself; it inherits dommy 0.9.0's CSS
cascade, computed styles, and accessibility tree, and now drives check/choose
through native click activation.

## 0.8.0 — 2026-05-31

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.8.0.
No functional changes to capybara-dommy itself.

## 0.7.0 — 2026-05-30

Initial release.

Versioned in lockstep with the [`dommy`](https://github.com/takahashim/dommy)
gem. capybara-dommy is a Capybara driver backed by `dommy` and `dommy-rack`. It
drives Rack/Rails apps through the Capybara DSL without a real browser or
JavaScript, keeping the page as a `Dommy::Document` (RackTest-like, with
HTML-level visibility).
