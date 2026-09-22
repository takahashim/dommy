# Capybara::Dommy

`capybara-dommy` is a [Capybara](https://github.com/teamcapybara/capybara) driver backed by
[Dommy](https://github.com/takahashim/dommy) and `dommy-rack`.

It drives Rack and Rails applications through the normal Capybara DSL without
starting a real browser. The current page is kept as a `Dommy::Document`, so
tests can inspect and interact with parsed HTML while staying close to the
speed and simplicity of a Rack-style driver.

## Features

- Visits Rack endpoints without a browser process or JavaScript runtime.
- Supports Capybara navigation, CSS/XPath queries, scoped `within` queries,
  status codes, response headers, page title, and serialized HTML.
- Supports common HTML interactions: links, buttons, form submission, text
  fields, textareas, checkboxes, radios, selects, ranges, labels, details, and
  file uploads.
- Preserves session state such as cookies, follows redirects by default, and
  supports browser-like back, forward, and refresh navigation.
- Implements HTML-level visibility through `dommy-rack`.
- In JavaScript-enabled mode, supports Capybara's `accept_alert`,
  `accept_confirm`, `dismiss_confirm`, `accept_prompt`, and `dismiss_prompt`
  helpers with deterministic responses.
- Provides a Rails convenience require for `driven_by :dommy`.

## Limitations

`capybara-dommy` is intentionally not a browser automation driver.

- The default driver does not execute JavaScript. Use the JavaScript-enabled
  variant for embedded QuickJS execution.
- Screenshots and browser windows are not supported. Native alerts, confirms,
  and prompts are supported by the JavaScript-enabled variant through
  Capybara's modal helpers.
- Constructable stylesheets can be built (`new CSSStyleSheet()`), but
  `adoptedStyleSheets` is not implemented — assigning one applies no style.
  Component libraries that feature-detect (`'adoptedStyleSheets' in
  Document.prototype`) fall back to injecting a `<style>`, which is handled.
- CSS layout is not calculated. Visibility is based on HTML-level rules such as
  `hidden`, `type="hidden"`, and inline `display: none` handling provided by
  `dommy-rack`.

By default, `execute_script`, `evaluate_script`, and
`evaluate_async_script` raise `Capybara::NotSupportedByDriverError`. You can
turn those calls into no-ops with configuration when migrating tests that call
JavaScript helpers incidentally.

## How this differs from a browser driver

Specs written against `capybara-dommy` use the ordinary Capybara DSL, so most
of them read the same as they would under selenium or cuprite. A few behaviours
underneath are genuinely different, and they are the ones worth knowing before
you port a suite.

**JavaScript errors fail the example.** A `javascript: true` driver fails on
anything the page's JavaScript left unhandled, at the next Capybara command, the
way Capybara's own `raise_server_errors` fails on a server exception. "Unhandled"
is the page's verdict: an error it cancels in `window.onerror` or in an
`unhandledrejection` listener never reaches the log, exactly as it never reaches
a browser console. A real browser driver reports nothing here, so this catches
breakage those drivers let through — usually a Dommy API the page needs and
Dommy does not implement yet. Turn it off with
`config.raise_js_errors = false`, or suppress it for one block with
`page.driver.allow_js_errors { ... }`.

**There are two clocks.** Dommy's timers run on a virtual clock that Capybara's
retry loop advances a frame at a time, so a debounce or a `setTimeout` resolves
in a few polls rather than in real time. Nothing advances it outside that loop:
`sleep` does not, and Rails' `travel_to` does not reach JavaScript's `Date`.

**The app runs in the test process.** There is no server thread and no port, so
`use_transactional_tests` works unchanged and an exception in the app is raised
directly in the test. In exchange, `Capybara.server` and anything built on a
separate app thread has no meaning here.

**There is no layout.** Visibility comes from HTML-level rules and stylesheet
`display` / `visibility` / `opacity`, never from geometry, so `obscured?`,
scroll position and element size are unavailable.

**Input is synthesised.** Events are dispatched from Ruby rather than by the OS,
so `isTrusted` is false and hover, drag and special keys are limited. An
unanswered `confirm` returns false rather than blocking.

**Frames are fetched, not live.** Switching to a frame re-requests its URL; the
frame's own scripts do not run.

**Failure artifacts are different.** `save_screenshot` raises (there is nothing
to paint). A failing example writes the page HTML and a trace bundle instead,
which `dommy-rails` wires up automatically.

## Installation

Add the gem to your application's Gemfile:

```ruby
gem "capybara-dommy"
```

Then run:

```bash
bundle install
```

Until the gem is available from RubyGems, install it from GitHub:

```ruby
gem "capybara-dommy", github: "takahashim/capybara-dommy"
```

`capybara-dommy` requires Ruby 3.2 or newer.

## Usage

For a plain Rack app, require the gem and register a Capybara driver:

```ruby
require "capybara/dommy"

Capybara.register_driver(:dommy) do |app|
  Capybara::Dommy::Driver.new(app)
end

Capybara.default_driver = :dommy
```

You can then use the normal Capybara DSL:

```ruby
visit "/"
click_link "New post"
fill_in "Title", with: "Hello"
click_button "Create"

expect(page).to have_text("Created")
```

### Rails System Tests

For Rails system tests, require the Rails integration and use
`driven_by :dommy`:

```ruby
# test/application_system_test_case.rb or spec/rails_helper.rb
require "capybara/dommy/rails"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :dommy
end
```

The Rails integration only registers the driver. Driver defaults still come from
`Capybara::Dommy.configuration`.

## Configuration

Configure process-wide defaults before creating sessions:

```ruby
Capybara::Dommy.configure do |config|
  config.default_host = "http://example.org"
  config.follow_redirects = true
  config.max_redirects = 5
  config.visibility = :html
  config.raise_on_unsupported_js = true
  config.raise_js_errors = true
end
```

Available options:

- `default_host`: host used for relative visits. Defaults to
  `"http://example.org"`.
- `follow_redirects`: whether Rack redirects are followed automatically.
  Defaults to `true`.
- `max_redirects`: maximum redirect count. Defaults to `5`.
- `visibility`: one of `:html`, `:all`, or `:none`. `:html` uses
  `dommy-rack` visibility checks. `:all` and `:none` treat every element as
  visible.
- `raise_on_unsupported_js`: when `true`, JavaScript methods raise
  `Capybara::NotSupportedByDriverError`; when `false`, they return `nil`.
- `raise_js_errors`: when `true` (the default), a `javascript: true` driver
  fails the example on JavaScript the page left unhandled. Has no effect on a
  driver that runs no JavaScript. See "How this differs from a browser driver".

You can also override driver options per registration:

```ruby
Capybara.register_driver(:dommy) do |app|
  Capybara::Dommy::Driver.new(
    app,
    default_host: "http://test.example",
    follow_redirects: true,
    max_redirects: 10,
    visibility: :html
  )
end
```

## Development

After checking out the repository, install dependencies:

```bash
bin/setup
```

Run the full test suite:

```bash
bundle exec rake spec
```

Run only the fast unit specs:

```bash
bundle exec rake spec:unit
```

Run only Capybara's shared driver compliance suite:

```bash
bundle exec rake spec:compliance
```

Open an interactive console:

```bash
bin/console
```

Install the gem locally:

```bash
bundle exec rake install
```

## Contributing

Bug reports and pull requests are welcome on GitHub:
<https://github.com/takahashim/capybara-dommy>.

## License

The gem is available as open source under the terms of the MIT License.
