# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe "Capybara DSL over the :dommy driver" do
  # The end-to-end example from the spec, driven through the Capybara DSL.
  it "visits, clicks a link, fills in, and submits" do
    app = app_for(
      "GET /" => html_response('<h1>Home</h1><a href="/posts/new">New post</a>'),
      "GET /posts/new" => html_response(
        '<form action="/posts" method="post">' \
        '<label>Title<input type="text" name="post[title]"></label>' \
        '<button type="submit">Create</button></form>'
      ),
      "POST /posts" => [302, {"Location" => "/posts/1"}, []],
      "GET /posts/1" => html_response('<p class="notice">Created</p>')
    )
    page = session_for(app)

    page.visit("/")
    page.click_link("New post")
    expect(page.current_path).to eq("/posts/new")

    page.fill_in("Title", with: "Hello")
    page.click_button("Create")

    expect(page.current_path).to eq("/posts/1")
    expect(page.has_text?("Created")).to be(true)
    expect(page.has_selector?("p.notice", text: "Created")).to be(true)
  end

  # Filling a single-field form with a value ending in "\n" implicitly
  # submits the form, mirroring pressing Enter in a lone text input.
  it "submits a single-field form when the value ends in a newline" do
    captured = nil
    app = app_for(
      "GET /" => html_response(
        '<form action="/search" method="get">' \
        '<label>Query<input type="text" name="q"></label></form>'
      ),
      "GET /search" => ->(req) {
        captured = req.params["q"]
        html_response("<p id='r'>#{captured}</p>")
      }
    )
    page = session_for(app)
    page.visit("/")
    page.fill_in("Query", with: "capybara\n")

    expect(page.current_path).to eq("/search")
    expect(captured).to eq("capybara")
    expect(page.find("#r").text).to eq("capybara")
  end

  it "checks, chooses, selects, and submits" do
    captured = nil
    app = app_for(
      "GET /" => html_response(
        '<form action="/s" method="post">' \
        '<input type="checkbox" name="tos" value="1" id="tos"><label for="tos">Agree</label>' \
        '<input type="radio" name="plan" value="basic" id="b"><label for="b">Basic</label>' \
        '<input type="radio" name="plan" value="pro" id="p"><label for="p">Pro</label>' \
        '<select name="color"><option>Red</option><option>Green</option></select>' \
        '<button type="submit">Go</button></form>'
      ),
      "POST /s" => ->(req) {
        captured = req.params
        html_response("<p>ok</p>")
      }
    )
    page = session_for(app)
    page.visit("/")
    page.check("Agree")
    page.choose("Pro")
    page.select("Green", from: "color")
    page.click_button("Go")

    expect(captured["tos"]).to eq("1")
    expect(captured["plan"]).to eq("pro")
    expect(captured["color"]).to eq("Green")
  end

  it "persists cookies across a redirect" do
    app = app_for(
      "GET /login" => [200, {"Content-Type" => "text/html", "Set-Cookie" => "sid=42; path=/"},
                       ['<form action="/go" method="post"><button type="submit">Go</button></form>']],
      "POST /go" => [302, {"Location" => "/dash"}, []],
      "GET /dash" => ->(req) { html_response("<p id='r'>#{req.cookies["sid"]}</p>") }
    )
    page = session_for(app)
    page.visit("/login")
    page.click_button("Go")
    expect(page.current_path).to eq("/dash")
    expect(page.find("#r").text).to eq("42")
  end

  it "honours _method override for DELETE" do
    seen = nil
    app = app_for(
      "GET /" => html_response(
        '<form action="/posts/1" method="post">' \
        '<input type="hidden" name="_method" value="delete">' \
        '<button type="submit">Destroy</button></form>'
      ),
      "DELETE /posts/1" => ->(req) { seen = req.request_method; html_response("<p>gone</p>") }
    )
    page = session_for(app)
    page.visit("/")
    page.click_button("Destroy")
    expect(seen).to eq("DELETE")
    expect(page.has_text?("gone")).to be(true)
  end

  it "attaches and uploads a file" do
    tempfile = Tempfile.new(["up", ".txt"])
    tempfile.write("hello upload")
    tempfile.flush

    app = app_for(
      "GET /" => html_response(
        '<form action="/u" method="post" enctype="multipart/form-data">' \
        '<label for="doc">Doc</label><input type="file" name="doc" id="doc">' \
        '<button type="submit">Send</button></form>'
      ),
      "POST /u" => ->(req) {
        f = req.params["doc"]
        html_response("<p id='r'>#{f[:filename]}:#{f[:tempfile].read}</p>")
      }
    )
    page = session_for(app)
    page.visit("/")
    page.attach_file("Doc", tempfile.path)
    page.click_button("Send")
    expect(page.find("#r").text).to eq("#{File.basename(tempfile.path)}:hello upload")
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  it "attaches and uploads multiple files" do
    files = Array.new(2) do |i|
      tf = Tempfile.new(["m#{i}", ".txt"])
      tf.write("content-#{i}")
      tf.flush
      tf
    end

    app = app_for(
      "GET /" => html_response(
        '<form action="/u" method="post" enctype="multipart/form-data">' \
        '<label for="docs">Docs</label><input type="file" name="docs[]" id="docs" multiple>' \
        '<button type="submit">Send</button></form>'
      ),
      "POST /u" => ->(req) {
        uploaded = req.params["docs"]
        names = Array(uploaded).map { |u| u[:filename] }.join(",")
        html_response("<p id='r'>#{names}</p>")
      }
    )
    page = session_for(app)
    page.visit("/")
    page.attach_file("Docs", files.map(&:path))
    page.click_button("Send")
    files.each { |tf| expect(page.find("#r").text).to include(File.basename(tf.path)) }
  ensure
    files&.each { |tf| tf.close; tf.unlink }
  end

  it "scopes queries with #within" do
    app = app_for("GET /" => html_response(
      '<div id="a"><span class="x">in-a</span></div>' \
      '<div id="b"><span class="x">in-b</span></div>'
    ))
    page = session_for(app)
    page.visit("/")
    page.within("#b") do
      expect(page.find(".x").text).to eq("in-b")
    end
  end

  it "resets the session between uses" do
    app = app_for("GET /set" => [200, {"Content-Type" => "text/html", "Set-Cookie" => "x=1; path=/"}, ["<p>set</p>"]])
    page = session_for(app)
    page.visit("/set")
    page.driver.reset!
    expect(page.driver.rack_session.cookies).to be_empty
  end
end
