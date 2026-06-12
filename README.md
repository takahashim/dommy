# Dommy

A pure-Ruby, browser-like DOM stack for testing Rack/Rails apps without a real browser.
This repository is a monorepo containing the core library and its integration gems.

## Gems

| Gem | Path | Description |
| --- | --- | --- |
| [`dommy`](gems/dommy) | `gems/dommy` | happy-dom-style DOM polyfill in pure Ruby (Makiri backend). |
| [`dommy-rack`](gems/dommy-rack) | `gems/dommy-rack` | Rack-backed, browser-like session layer over a `Dommy::Document`. |
| [`capybara-dommy`](gems/capybara-dommy) | `gems/capybara-dommy` | A Capybara driver backed by `dommy` and `dommy-rack`. |
| [`dommy-rails`](gems/dommy-rails) | `gems/dommy-rails` | Rails-specific DOM matchers and assertions for request/view/component/mailer specs. |

Each gem keeps its own `gemspec`, `README`, and test suite, and is released to RubyGems independently.

> [!NOTE]
> [`dommy-js-quickjs`](https://github.com/takahashim/dommy-js-quickjs) (a QuickJS
> JavaScript backend) lives in its own repository because it depends on the
> native `quickjs` gem with a separate build/release cadence.

## Development

A single root `Gemfile` resolves all gems from their local paths, so no `path:` overrides are needed:

```sh
bundle install
```

### Running tests

```sh
# Every gem
bundle exec rake test

# A single gem
bundle exec rake test:dommy
bundle exec rake test:dommy-rack
bundle exec rake test:capybara-dommy
bundle exec rake test:dommy-rails
```

You can also run a gem's suite from its own directory:

```sh
cd gems/dommy && bundle exec rake
```

`dommy`, `dommy-rack`, and `dommy-rails` use Minitest; `capybara-dommy` uses RSpec (including the Capybara driver compliance suite).

## Releasing

Build and push each gem from its own subdirectory:

```sh
cd gems/dommy && bundle exec rake release
```

## License

MIT — see [LICENSE.txt](LICENSE.txt).
