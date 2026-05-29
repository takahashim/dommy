# Dommy::Rack

`dommy-rack` lets a Rack application (including Rails) be visited and manipulated as a [Dommy](https://github.com/takahashim/dommy) `Document`, without launching a real browser.
It provides a small, synchronous, browser-like session API: navigation, cookies, redirects, link clicking, form submission, JSON requests, and simple matchers.

There is no JavaScript engine and no network: requests are dispatched straight to your Rack app object, and responses are parsed into a Dommy DOM.
This makes it a fast backend for integration tests and a building block for higher-level drivers such as [capybara-dommy](https://github.com/takahashim/capybara-dommy).

## Installation

```ruby
# Gemfile
gem "dommy-rack"
```

```bash
bundle install
```

## Quick start

```ruby
require "dommy/rack"

session = Dommy::Rack::Session.new(MyRackApp)

session.visit("/")
session.click_link("New post")

session.fill_in("post[title]", with: "Hello")
session.click_button("Create")

session.current_path        # => "/posts/1"
session.at_css(".notice").text_content  # => "Created"
```

`Session.new` accepts any Rack-callable `app` plus options:

| option | default | meaning |
| --- | --- | --- |
| `default_host` | `"http://example.org"` | base for relative URLs |
| `follow_redirects` | `true` | follow 3xx responses |
| `max_redirects` | `5` | redirect / meta-refresh limit |
| `respect_method_override` | `true` | honor Rails `_method` |
| `method_override_param` | `"_method"` | override param name |
| `user_agent` | `"DommyRack"` | default `User-Agent` |
| `accept` | HTML accept string | default `Accept` |
| `enforce_same_origin` | `true` | block cross-origin requests |
| `follow_meta_refresh` | `true` | follow `<meta http-equiv="refresh">` (delay 0) |

## Navigation

```ruby
session.visit("/path")
session.get("/path", headers: {})
session.post("/path", params: {a: 1})
session.put("/path", params: {})
session.patch("/path", params: {})
session.delete("/path")
session.request("REPORT", "/path", params: {})

session.reload
session.back
session.forward

session.current_url    # full URL
session.current_path   # path component
session.current_host
```

`fetch` issues a request **without** changing the current page or history, and returns the `Response` directly:

```ruby
res = session.fetch("/api/ping", redirect: :manual) # :follow | :manual | :error
res.status
```

## Inspecting the current page

```ruby
session.status      # last response status (Integer)
session.headers     # last response headers (Hash)
session.body        # raw response body (String)
session.html        # serialized document HTML
session.text        # document body text

session.success?       # 2xx
session.not_found?     # 404
session.client_error?  # 4xx
session.server_error?  # 5xx

session.save_page                 # write HTML to a temp file, returns path
session.save_page("out.html")     # write to a specific path
```

### DOM queries

```ruby
session.at_css("h1")          # first match (a Dommy element) or nil
session.all_css("li")         # all matches
session.at_xpath("//h1")
session.all_xpath("//li")
```

### Redirect chain

```ruby
session.visit("/a")     # /a -> /b -> /c
session.redirected?     # => true
session.redirects       # => [{status: 302, url: ".../a", location: "/b"}, ...]
```

## Forms

```ruby
session.fill_in("Email", with: "a@example.com")  # by label, id, name, placeholder, aria-label
session.choose("Male")                            # radio
session.check("Subscribe")                        # checkbox
session.uncheck("Subscribe")
session.select("Tokyo", from: "City")             # <select>
session.unselect("Tokyo", from: "City")
session.attach_file("Avatar", "/path/to/file.png")

session.click_button("Save")        # submits the owning form
session.submit_form(session.at_css("form"))
```

Locators are Capybara-style and depend on the element type:
fields match by `id`, `name`, label text, placeholder, or `aria-label`;
links match by visible text, `id`, `title`, or exact `href`;
buttons match by button text, `value`, `id`, `name`, or `alt`.

## JSON

```ruby
session.post_json("/api/posts", {title: "Hi"})    # also put_json / patch_json / delete_json
session.status                                     # => 201
session.json                                       # => {"id" => 7}
session.json(symbolize_names: true)                # => {id: 7}

# On a Response:
res = session.fetch("/api/posts")
res.json?   # content-type is JSON-ish (application/json, text/json, *+json)
res.json    # parsed body (parses regardless of content-type)
```

A `String` passed to `post_json` is sent verbatim (already-encoded JSON).
`Content-Type` and `Accept` default to `application/json` and can be overridden via `headers:`.

## Persistent headers and authentication

```ruby
session.set_header("X-Api-Key", "secret")  # sent on every request
session.delete_header("X-Api-Key")
session.default_headers                     # current persistent headers (copy)

session.basic_auth("alice", "s3cret")       # Authorization: Basic ...
session.authorization_bearer("token123")    # Authorization: Bearer token123
```

Per-request `headers:` override persistent defaults (case-insensitively).

## Cookies

```ruby
session.cookies                       # all cookies
session.get_cookie("sid")
session.set_cookie("sid", "42", path: "/")
session.clear_cookies
```

Cookies set by the app via `Set-Cookie` are stored and replayed automatically.

## Scoping and matchers

```ruby
session.within("#sidebar") do |s|
  s.click_link("Help")
  s.has_text?("Contact us")   # scoped to #sidebar
end

session.has_css?(".item", count: 3)
session.has_no_css?(".error")
session.has_text?("Welcome")
session.has_no_text?("Error")
session.has_link?("Home")
session.has_button?("Save")
session.has_field?("Email")
```

### iframes

```ruby
session.within_frame("preview") do |s|   # by id, name, CSS, or the sole frame
  s.has_text?("inside the iframe")
end
```

`within_frame` fetches the iframe's `src` as a sub-document and scopes finds and matchers to it for the block.

## Instrumentation

```ruby
session.on_request  { |env|      Rails.logger.info("-> #{env["PATH_INFO"]}") }
session.on_response { |response| Rails.logger.info("<- #{response.status}") }
```

## Errors

All errors inherit from `Dommy::Rack::Error`:
`ElementNotFoundError`, `AmbiguousElementError`, `ElementNotClickableError`,
`UnsupportedURLError`, `CrossOriginError`, `TooManyRedirectsError`,
`UnsupportedContentTypeError`, `InvalidFormError`, `FileNotFoundError`.

## Development

```bash
bin/setup        # install dependencies
rake test        # run the test suite
bin/console      # interactive prompt
```

## Contributing

Bug reports and pull requests are welcome at
https://github.com/takahashim/dommy-rack.

## License

Available as open source under the [MIT License](https://opensource.org/licenses/MIT).
