# Dommy

A pure-Ruby DOM polyfill on top of [Nokogiri::HTML5](https://nokogiri.org/) — a Ruby-side analogue to happy-dom / jsdom.
Dommy exposes browser-like DOM semantics (events, MutationObserver, Custom Elements, Shadow DOM, File API, timers, Storage) so view / component / request specs can verify DOM structure and behavior without spinning up a real browser.

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
file = Dommy::File.new(["pdf body"], "doc.pdf", "type" => "application/pdf")

# Seed a file input for tests
input = dom.query_selector("input[type='file']")
input.__set_files__([file])

# FormData picks it up
fd = Dommy::FormData.new(dom.query_selector("form"))
fd.entries.to_a   #=> [["attachment", #<Dommy::File doc.pdf>]]

# Drag-and-drop simulation
dt = Dommy::DataTransfer.new(files: [file])
ev = Dommy::DragEvent.new("drop", "dataTransfer" => dt, "bubbles" => true)
dropzone.dispatch_event(ev)

# Blob URLs
url = Dommy::URL.create_object_url(blob)   # "blob:dommy/..."
```

### Async / Promise#await

Dommy's async surfaces (fetch, custom JS promises) return `PromiseValue`. Use `.await` from Ruby to unwrap synchronously:

```ruby
response = win.__js_call__("fetch", ["/api"]).await
```

> [!WARNING]
> Most Dommy accessors (`Blob#text`, `Response#text`, `localStorage.get_item`) return synchronous Ruby values — not Promises. `.await` is for the JS-bridged async surface.

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
- 26 specialized HTMLElement subclasses
- SVG: SVGElement base + ~63 specialized subclasses covering shapes, gradients, marker / mask, the full set of standard filter primitives (Gaussian blur, offset, blend, color matrix, flood, composite, merge, component transfer, tile, morphology, image, drop shadow, turbulence, displacement map, convolve matrix, diffuse / specular lighting + light sources), `<a>` / `<textPath>` / `<view>` / `<switch>` / `<metadata>`, and SMIL animation (`<animate>` / `<animateTransform>` / `<animateMotion>` / `<set>` / `<mpath>` / `<discard>`) — with case-sensitive attribute round-trip
- events with composedPath / AbortSignal
- MutationObserver (childList / attributes / characterData / subtree)
- Custom Elements lifecycle
- Shadow DOM (open/closed, slots, event composition)
- form validation
- Scheduler (timers + microtasks with `advance_time`)
- Promise
- Location / History / URL
- Storage
- fetch (stub)
- Navigator / Clipboard
- TreeWalker / NodeIterator / NodeFilter
- File API (Blob / File / FileList / FormData / DataTransfer)
- Web Crypto (`crypto.randomUUID`, `getRandomValues`) / TextEncoder / TextDecoder
- IntersectionObserver / ResizeObserver / PerformanceObserver (test-driven `__trigger__`)
- Range / Selection (DOM-level only, no layout)
- Web Animations API (Animation / KeyframeEffect; lifecycle via scheduler, finished/ready Promises)
- Extended events: Touch / Clipboard / Composition / Wheel / Focus / BeforeUnload / Input / Pointer / Progress / Drag

> [!IMPORTANT]
> Out of scope:
>
> - requires a layout / CSS engine or media subsystems: real `getBoundingClientRect` / scroll metrics
> - CSS scoping (`:host`, `::slotted`, computed styles)
> - JS evaluation
> - Canvas / WebGL / media playback
> - layout-dependent Range / Selection geometry (`getBoundingClientRect` returns zero rects)
> - SVG-specific value types (SVGAnimatedLength, SVGTransform, SVGMatrix)
> - Web Animations: no actual value interpolation — `Animation` is a state machine (`idle` / `running` / `paused` / `finished`) for testing lifecycle and event wiring

## Running the tests

```sh
$ bundle install
$ bundle exec rake test
```

## License

MIT
