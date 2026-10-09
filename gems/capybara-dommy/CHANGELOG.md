# Changelog

## Unreleased

### Added

- `drag_to` under JavaScript: a press inside a draggable element runs an HTML drag-and-drop (`dragstart` through `drop` and `dragend`), anything else moves the pointer to the target and releases it there (`mousemove`, `mouseup`), with `delay` (0.05 s) of virtual time between the steps.
- `current_window.size` and `current_window.resize_to(width, height)`: the one window starts at 1280x720, and its size is the viewport `@media` and `matchMedia` see, kept across `reset!`.

### Changed

- With `Capybara.raise_server_errors = false`, an exception the app raises gives the page a 500 response with Puma's error text instead of failing the test; an exception not in `Capybara.server_errors` gives the same 500.
- Under JavaScript, a Capybara wait (`default_max_wait_time`, `wait:`) is a span of the page's virtual time: a retry moves the clock to the page's next timer within it instead of sleeping, and a query that nothing within the wait can satisfy fails at once. dommy-examples' debounced live search runs its system specs at 41 ms an example instead of 296 ms, and `have_no_css` on an element that stays fails in milliseconds instead of after the wait. Only an open WebSocket or EventSource is waited for in real time.
- A node whose element left the tree (a Turbo Stream replaced it, a framework re-rendered it) is stale, as under Selenium, so Capybara finds it again instead of reading the detached element.

## 0.15.0 — 2026-10-04

### Changed

- Requires dommy and dommy-rack ~> 0.15.0.
- `attach_file` sets a file input's files through `input.files =`, as script does; `__driver_set_files__` is gone from dommy.

## 0.14.0 — 2026-10-01

### Added

- `right_click` and `double_click`, which fire `contextmenu` and `dblclick` after the full pointer and mouse sequence under JavaScript. Without JavaScript `double_click` is a `click`.
- `shadow_root` returns the element's shadow tree as a node, so `find(...).shadow_root.find(...)` searches inside it.
- `execute_script` / `evaluate_script` pass their arguments to the script, a Capybara node arriving as its element.
- A frame with `srcdoc` loads that document, at `about:srcdoc`.
- `save_screenshot` writes a blank PNG at the path and the page's HTML and visible text next to it, so Rails' failure screenshot no longer raises and hides the real failure.

### Changed

- `hover` under JavaScript fires `mouseover` and `mouseenter` on the element (and `mouseout` / `mouseleave` on the one it leaves), not only the `:hover` state.
- `send_keys` without JavaScript applies `:backspace`, `:delete`, `:home` and `:end` at the caret, and `:enter` inserts a newline in a textarea and submits an input's form.

## 0.13.0 — 2026-09-23

### Added

- `Capybara::Dommy.configuration.raise_js_errors` (default `true`) fails an example on JavaScript the page left unhandled, at the next Capybara command, the way Capybara's own `raise_server_errors` fails one on a server exception. It affects only a `javascript: true` driver.
- `page.driver.allow_js_errors { ... }` suppresses that failure for a block.
- README: a "How this differs from a browser driver" section.

## 0.12.0 — 2026-09-22

Versioned in lockstep with [`dommy`](https://github.com/takahashim/dommy) 0.12.0.
No functional changes to capybara-dommy itself.

## 0.11.0 — 2026-09-11

### Added
- **Native dialog helpers in JS mode.** `accept_confirm`, `dismiss_confirm`, `accept_alert`, `accept_prompt` (with `with:`) and `dismiss_prompt` work against the page's real `confirm` / `alert` / `prompt`, including a `text:` string or Regexp to say which dialog is expected. Nested helper blocks answer the dialogs in the order the page opens them, and a dialog nobody is waiting for falls back to the headless default, so a stray `confirm` cannot silently accept. A block that opens no matching dialog raises `Capybara::ModalNotFound`, naming what turned up instead.

### Fixed
- Turbo-driven navigation in JS apps is followed, so `have_current_path` and the matchers after a Turbo visit see the page the app actually moved to.
- `current_url` advances the virtual clock like the other queries do, so a `have_current_path` poll converges when the navigation settles in a scheduled task rather than a microtask.

## 0.10.0 — 2026-07-13

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
