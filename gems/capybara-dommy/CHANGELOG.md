# Changelog

## Unreleased

### Added
- **JavaScript-enabled driver variant** (`:dommy_js`, or `Driver.new(app, javascript: true)` / `config.javascript`): pages run their real Turbo/Stimulus/React bundles in the embedded QuickJS runtime, no browser process. Node interactions behave like a browser instead of the HTML-only fast paths — `click` dispatches the full pointer/mouse/click sequence before the default action (Turbo can `preventDefault` and take over), `set` types with focus + `input` / `change` events, `select_option` fires `input` / `change`, and `send_keys` dispatches real keyboard events. `execute_script` / `evaluate_script` run for real, and a time pump advances the virtual clock inside Capybara's synchronize loop so waiting matchers converge. Requires `dommy-js-quickjs`.

### Fixed
- The dommy-rack session is fully disposed on `reset!` and when the effective host changes, so JS runtimes and open WebSocket transports no longer leak across tests.

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
