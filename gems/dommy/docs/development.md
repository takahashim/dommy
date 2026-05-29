# Development

Notes for contributors working on Dommy's internals.

## Ecosystem

Dommy is the base of a three-gem stack, each layer depending on the one below:

- **dommy** — a pure-Ruby DOM polyfill over a pluggable parsing backend
  (Nokogiri::HTML5 by default; nokolexbor experimental).
- **dommy-rack** — a Rack-backed browser-session layer (navigation, form
  submission, multipart encoding) that drives a Dommy document.
- **capybara-dommy** — a Capybara driver built on dommy-rack.

The `__driver_` / `__dommy_` method prefixes below refer to these gem
boundaries.

## Method naming conventions

Dommy emulates the Web platform, so its public Ruby API uses plain
`snake_case` names that mirror the corresponding Web API. Methods that are
*not* part of that public surface carry a double-underscore-bookended prefix
that names **who is allowed to call them and across which boundary**:

| Prefix | Meaning | Intended caller |
|---|---|---|
| `__js_*__`       | JS bridge ABI                          | the JS bridge runtime (`__js_get__` / `__js_set__` / `__js_call__`) |
| `__internal_*__` | Dommy-gem-internal plumbing            | other classes **within** the `dommy` gem only |
| `__test_*__`     | user test support                      | end-user / Dommy specs simulating the *environment* (GPS, server push, permission grants, observer firing) |
| `__driver_*__`   | driver / integration privileged hooks  | driver gems (`capybara-dommy`, `dommy-rack`) performing privileged user-action emulation the Web API forbids |
| `__dommy_*__`    | low-level Dommy-ecosystem protocols    | any gem in the Dommy ecosystem (cross-gem, lower-level than a driver hook) |

Disambiguating the adjacent buckets:

- **`__internal_` vs `__dommy_`** — the discriminator is the *gem boundary*:
  if removing it would break another gem, it's `__dommy_`; if only `dommy`
  itself calls it, it's `__internal_`.
- **`__test_` vs `__driver_`** — the discriminator is *what is driven*:
  `__test_` simulates the **external environment** from a user's spec;
  `__driver_` implements **Capybara/Rack interaction semantics** from a
  driver gem (e.g. attaching files to an `<input>`, which JS can't do because
  `input.files` is read-only).

Instance variables (`@__node__` etc.) are private state, not API, and are
exempt from these conventions.

## JS bridge protocol

DOM wrapper classes expose a string-keyed bridge so an external runtime (e.g.
an mruby-on-wasm host) can route property reads/writes and method calls through
a uniform interface:

- `__js_get__(name)` — read a property by string name
- `__js_set__(name, value)` — write one
- `__js_call__(method, args)` — invoke a method with positional `args` (Array)
- `__js_new__(args)` — invoke the value as a JS constructor

CRuby users writing happy-dom-style tests can ignore this protocol entirely; it
only matters when integrating with a JS bridge. See
[`lib/dommy/bridge.rb`](../lib/dommy/bridge.rb) for the adapter classes and the
full contract.
