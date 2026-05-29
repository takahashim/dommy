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
- Provides a Rails convenience require for `driven_by :dommy`.

## Limitations

`capybara-dommy` is intentionally not a browser automation driver.

- JavaScript is not executed.
- Screenshots, browser windows, alerts, confirms, prompts, and other real
  browser features are not supported.
- CSS layout is not calculated. Visibility is based on HTML-level rules such as
  `hidden`, `type="hidden"`, and inline `display: none` handling provided by
  `dommy-rack`.

By default, `execute_script`, `evaluate_script`, and
`evaluate_async_script` raise `Capybara::NotSupportedByDriverError`. You can
turn those calls into no-ops with configuration when migrating tests that call
JavaScript helpers incidentally.

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
