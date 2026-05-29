# Dommy

Dommy is a pure Ruby DOM polyfill built on [Nokogiri::HTML5](https://nokogiri.org/), inspired by happy-dom and jsdom.
It gives Ruby tests a browser style DOM with events, MutationObserver, Custom Elements, Shadow DOM, the File API, timers, and Storage, without requiring a real browser.

## Quick start

```ruby
require "dommy"

win = Dommy.parse("<div id='root'><button class='primary'>Click me</button></div>")
btn = win.document.query_selector(".primary")

clicks = 0
btn.on("click") { clicks += 1 }
btn.click
clicks   #=> 1
```

## Installation

```ruby
# Gemfile
gem "dommy"
```

## Highlights

### DOM operations

```ruby
doc = win.document
li = doc.create_element("li")
li.text_content = "added"
doc.body.append_child(li)
doc.query_selector_all("li").length   #=> 1
```

### Custom Elements + lifecycle callbacks

```ruby
class MyButton < Dommy::HTMLElement
  def self.observed_attributes = ["data-state"]
  def connected_callback
  end
  def attribute_changed_callback(name, old, new)
  end
end

win.custom_elements.define("my-button", MyButton)
```

### Shadow DOM

```ruby
host = win.document.create_element("my-card")
sr   = host.attach_shadow(mode: "open")
sr.inner_html = "<slot></slot>"

# Outer queries can't reach inside the shadow tree
win.document.query_selector("p")   # light DOM only
```

### Form validation

```ruby
input = win.document.create_element("input")
input.type = "email"
input.set_attribute("required", "")
input.check_validity        #=> false
input.validation_message    #=> "Please fill out this field."
```

### File API (Blob / File / FormData / DataTransfer)

```ruby
win = Dommy.parse("<form><input type='file' name='attachment'></form>")
file = Dommy::File.new(["pdf body"], "doc.pdf", "type" => "application/pdf")

# Seed a file input for tests
input = win.document.query_selector("input[type='file']")
input.__set_files__([file])

# FormData picks it up
fd = Dommy::FormData.new(win.document.query_selector("form"))
fd.entries.to_a   #=> [["attachment", #<Dommy::File doc.pdf>]]

# Drag-and-drop simulation
dt = Dommy::DataTransfer.new(files: [file])
ev = Dommy::DragEvent.new("drop", "dataTransfer" => dt, "bubbles" => true)
win.document.body.dispatch_event(ev)

# Blob URLs
blob = Dommy::Blob.new(["blob body"], "type" => "text/plain")
url = Dommy::URL.create_object_url(blob)   # "blob:dommy/..."
```

### Async / Promise#await

Dommy's async surfaces (fetch, custom JS promises) return `PromiseValue`. Use `.await` from Ruby to unwrap synchronously:

```ruby
response = win.__js_call__("fetch", ["/api"]).await
```

> [!WARNING]
> Most Dommy accessors (`Blob#text`, `localStorage.get_item`) return synchronous Ruby values — not Promises. `.await` is only for the JS-bridged async surface (e.g., `fetch()`, `window.__js_call__`). Methods like `Response#text()` are Promise-returning and require `.await`.

## Test helpers

Dommy ships test-side modules you can `include` into RSpec / Minitest. Matchers accept a `Dommy::Document` / element or a raw HTML string (auto-parsed), matching Capybara's `expect(rendered).to ...` ergonomics.

### Minitest

```ruby
require "dommy/minitest"

class UserCardTest < Minitest::Test
  include Dommy::TestHelpers
  include Dommy::Minitest::Assertions

  def test_renders
    dom = parse_html(render(UserCardComponent.new(name: "Alice")))
    assert_dom_contains(dom, "h2", text: "Alice")
    assert_dom_contains(dom, "li", count: 3)
  end
end
```

Assertions: `assert_dom_contains`, `assert_dom_contains_text`, `assert_dom_has_attribute`, `assert_dom_has_class`, `assert_dom_html_equal` (each with a `refute_` counterpart).

### RSpec — two matcher flavors

`require "dommy/rspec"` to get both flavors:

#### 1. `Dommy::RSpec::Matchers`

`_dom_` infix names, coexist with Capybara and `rails-dom-testing`:

```ruby
expect(rendered).to contain_dom("h2", text: "Alice")
expect(button).to have_dom_attribute("type", "submit")
expect(button).to have_dom_class("primary")
```

#### 2. `Dommy::RSpec::CapyStyleMatchers`

Capybara-compatible names for drop-in replacement in view / component / request specs:

```ruby
expect(rendered).to have_selector("h1", text: "Products")
expect(rendered).to have_link("Sign up", href: "/signup")
expect(rendered).to have_button("Submit")
expect(rendered).to have_no_selector(".hidden")
```

Use a `type:` split to keep real-browser Capybara on feature specs while letting Dommy run the rest:

```ruby
RSpec.configure do |c|
  c.include Capybara::DSL,                   type: :feature
  c.include Capybara::RSpecMatchers,         type: :feature

  %i[view component request controller helper].each do |t|
    c.include Dommy::TestHelpers,             type: t
    c.include Dommy::RSpec::CapyStyleMatchers, type: t
  end
end
```

Supported Capybara-style options: `text:` / `exact:` / `count:` (Integer or Range) / `visible:` / `href:` / `with:` / `type:`. `wait:` is accepted and ignored (Dommy is synchronous).

> [!CAUTION]
> `:visible` is HTML-level only. Dommy has no CSS engine, so `display: none` set via a CSS class is **not** detected. Detection covers the `hidden` attribute, `<input type=hidden>`, non-rendering ancestors (`head`/`script`/`style`/`template`), and inline `style="display: none"` / `visibility: hidden`. If you toggle visibility through a CSS class, assert on the class instead (`have_dom_class("hidden")`) or keep that spec on Capybara + a real browser.

## What's in scope

Implemented:

- Core DOM (Document, Element, Text/Comment/Fragment, NodeList, Attr)
- Specialized HTML and SVG element classes
- events with composedPath / AbortSignal
- MutationObserver (childList / attributes / characterData / subtree)
- Custom Elements lifecycle
- Shadow DOM (open/closed, slots, event composition)
- form validation
- Scheduler (timers + microtasks with `advance_time`)
- Promise
- Location / History / URL
- Storage
- fetch / XMLHttpRequest stubs
- WebSocket / EventSource / MessageChannel / BroadcastChannel test doubles
- FileReader / Notification / Geolocation / `matchMedia`
- `requestIdleCallback`, `structuredClone`, `URLPattern`
- Web Crypto, Streams, Compression Streams, Worker
- `performance`, `cookieStore`, Navigator extras
- Popover API, Fullscreen API, View Transitions API stub
- Navigator / Clipboard
- TreeWalker / NodeIterator / NodeFilter
- File API (Blob / File / FileList / FormData / DataTransfer)
- IntersectionObserver / ResizeObserver / PerformanceObserver (test-driven `__test_trigger__`)
- Range / Selection (DOM-level only, no layout)
- Web Animations API (Animation / KeyframeEffect)
- Extended events: Touch / Clipboard / Composition / Wheel / Focus / BeforeUnload / Input / Pointer / Progress / Drag

For implementation notes and tradeoffs, see [design.md](./design.md).

> [!IMPORTANT]
> Out of scope:
>
> - layout and CSS-engine behavior
> - JS evaluation
> - Canvas / WebGL / media playback
> - layout-dependent Range / Selection geometry
> - SVG-specific value types
> - animation value interpolation

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

> [!NOTE]
> This legend will move to a dedicated developer doc once one exists.

## Running the tests

```sh
$ bundle install
$ bundle exec rake test
```

## License

MIT
