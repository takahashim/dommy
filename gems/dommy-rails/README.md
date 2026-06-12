# dommy-rails

Rails integration for [Dommy](https://github.com/takahashim/dommy) —
provides Rails-specific DOM testing helpers for request specs, view specs,
component specs, and mailer specs.

## Features

- **Form helper understanding**: Detect Rails forms, `_method` override, CSRF tokens
- **Turbo Stream support**: Parse and assert Turbo Stream responses
- **Turbo Frame support**: Assert `<turbo-frame>` presence and contents
- **Stimulus checking**: Verify `data-controller`, `data-action`, `data-target`, `data-*-value`
- **Mailer assertions**: Check HTML and plain text mail bodies
- **HTML quality linting**: Find duplicate IDs, invalid ARIA references, missing form labels, empty links, and nested interactive elements
- **URL normalization**: Compare URLs accounting for host differences, query param ordering, HTML entities

## Installation

```ruby
gem "dommy-rails"
```

## Usage

### Minitest (ActionDispatch::IntegrationTest)

```ruby
require "dommy/rails/minitest"

class ArticlesControllerTest < ActionDispatch::IntegrationTest
  include Dommy::Rails::Minitest::Integration

  def test_index
    get articles_path
    
    assert_dom_has_css dom, "h1", text: "Articles"
    assert_dom_has_link dom, "New article", href: new_article_path
    assert_dom_has_form dom, action: articles_path, method: :post
    assert_dom_has_title dom, "Articles"
    assert_dom_has_csrf_meta_tags dom
    assert_dom_has_stimulus_controller dom, "articles"
    assert_dom_has_turbo_frame dom, "articles"
    assert_dom_no_duplicate_ids dom
    assert_dom_no_empty_links dom
  end

  def test_turbo_stream
    post articles_path, params: { article: { title: "Hello" } }, as: :turbo_stream
    
    assert_dom_appends_turbo_stream response, "articles" do |fragment|
      assert_dom_has_css fragment, ".article", text: "Hello"
    end
  end
end
```

### RSpec

```ruby
require "dommy/rails/rspec"

RSpec.configure do |config|
  config.include Dommy::Rails::RSpec::Integration, type: :request
  config.include Dommy::Rails::RSpec::Integration, type: :view
  config.include Dommy::Rails::RSpec::Integration, type: :component
  config.include Dommy::Rails::RSpec::Integration, type: :mailer
end
```

```ruby
RSpec.describe "Articles", type: :request do
  it "renders the index" do
    get articles_path

    expect(dom).to have_css("h1", text: "Articles")
    expect(dom).to have_link("New article", href: new_article_path)
    expect(dom).to have_form(action: articles_path, method: :post)
    expect(dom).to have_title("Articles")
    expect(dom).to have_csrf_meta_tags
    expect(dom).to have_stimulus_controller("articles")
    expect(dom).to have_no_duplicate_ids
    expect(dom).to have_no_empty_links
  end

  it "renders a Turbo Stream response" do
    post articles_path, params: { article: { title: "Hello" } }, as: :turbo_stream

    expect(response).to append_turbo_stream("articles") { |fragment|
      expect(fragment).to have_css(".article", text: "Hello")
    }
  end
end
```

Turbo Frames can be checked directly:

```ruby
expect(dom).to have_turbo_frame("articles") { |frame|
  expect(frame).to have_css(".article", text: "Hello")
}
```

Mailer specs can check mail objects directly:

```ruby
expect(mail).to have_html_link("Confirm your account", href: confirmation_url(user))
expect(mail).to have_html_text("Confirm your account")
expect(mail).to have_plain_text("Welcome")
```

## URL normalization

`have_link(href:)`, `have_form(action:)`, and their Minitest counterparts
absorb the representational differences between Rails URL helpers and
rendered HTML. Before comparison, both sides are normalized:

- scheme and host are dropped (`http://www.example.com/articles` ≡ `/articles`)
- query parameters are sorted (`?b=2&a=1` ≡ `?a=1&b=2`)
- HTML entities are unescaped (`&amp;` ≡ `&`)
- trailing slashes are removed (`/articles/` ≡ `/articles`)

This is deliberately lenient: because the host is ignored, an absolute
URL to an external site with the same path matches a relative `href:`.
Strict external-host matching is out of scope for now; pass a `Regexp`
as `href:` when you need to pin the host.

## License

MIT
