# frozen_string_literal: true

require "spec_helper"
require "support/null_runtime"

# The javascript: true driver path. The runtime is a no-JS NullRuntime — what
# these specs pin down is the driver's browser-like behavior around it: real
# DOM event sequences on interaction (observed by Ruby listeners), default
# actions gated on preventDefault, script delegation, and session disposal.
RSpec.describe "Capybara::Dommy::Driver with javascript: true" do
  before do
    @runtimes = []
    @previous_factory = CapybaraDommyJsSupport.install(@runtimes)
  end

  after do
    CapybaraDommyJsSupport.restore(@previous_factory)
  end

  def js_driver_for(html)
    driver = Capybara::Dommy::Driver.new(html_app(html), javascript: true)
    driver.visit("/")
    driver
  end

  def prevent_default
    ->(e) { e.__js_call__("preventDefault", []) }
  end

  it "reports javascript? and enables Capybara waiting" do
    driver = js_driver_for("<p>x</p>")
    expect(driver.javascript?).to be(true)
    expect(driver.wait?).to be(true)

    plain = Capybara::Dommy::Driver.new(html_app("<p>x</p>"))
    expect(plain.javascript?).to be(false)
  end

  describe "click" do
    it "dispatches the full pointer/mouse/click sequence" do
      driver = js_driver_for("<button id='b'>Go</button>")
      node = driver.find_css("#b").first
      seen = []
      %w[pointerdown mousedown pointerup mouseup click].each do |type|
        node.native.add_event_listener(type, ->(e) { seen << e.type })
      end

      node.click

      expect(seen).to eq(%w[pointerdown mousedown pointerup mouseup click])
    end

    it "follows a link when the click is not prevented" do
      app = app_for(
        "GET /" => html_response("<a id='l' href='/next'>next</a>"),
        "GET /next" => html_response("<h1>Next</h1>")
      )
      driver = Capybara::Dommy::Driver.new(app, javascript: true)
      driver.visit("/")

      driver.find_css("#l").first.click

      expect(driver.current_url).to eq("http://example.org/next")
    end

    it "does not navigate when a handler prevents the click (SPA takeover)" do
      app = app_for(
        "GET /" => html_response("<a id='l' href='/next'>next</a>"),
        "GET /next" => html_response("<h1>Next</h1>")
      )
      driver = Capybara::Dommy::Driver.new(app, javascript: true)
      driver.visit("/")
      node = driver.find_css("#l").first
      node.native.add_event_listener("click", prevent_default)

      node.click

      expect(driver.current_url).to eq("http://example.org/")
    end

    it "fires a cancelable submit whose prevention stops the form request" do
      posts = []
      app = lambda do |env|
        req = ::Rack::Request.new(env)
        posts << req.path if req.post?
        html_response("<form id='f' method='post' action='/save'>" \
                      "<button id='s' type='submit'>Save</button></form>")
      end
      driver = Capybara::Dommy::Driver.new(app, javascript: true)
      driver.visit("/")
      driver.document.query_selector("#f").add_event_listener("submit", prevent_default)

      driver.find_css("#s").first.click

      expect(posts).to be_empty
      expect(driver.current_url).to eq("http://example.org/")
    end

    it "performs the form submission when the submit event is not prevented" do
      posts = []
      app = lambda do |env|
        req = ::Rack::Request.new(env)
        posts << req.path if req.post?
        html_response("<form method='post' action='/save'>" \
                      "<button id='s' type='submit'>Save</button></form>")
      end
      driver = Capybara::Dommy::Driver.new(app, javascript: true)
      driver.visit("/")

      driver.find_css("#s").first.click

      expect(posts).to eq(["/save"])
    end
  end

  describe "field interaction" do
    it "set types with focus + input + change events" do
      driver = js_driver_for("<input id='q'>")
      node = driver.find_css("#q").first
      seen = []
      %w[focus input change].each do |type|
        node.native.add_event_listener(type, ->(e) { seen << e.type })
      end

      node.set("hello")

      expect(node.native.value).to eq("hello")
      expect(seen).to eq(%w[focus input change])
    end

    it "select_option fires input and change on the select" do
      driver = js_driver_for(
        "<select id='s'><option value='a'>A</option><option value='b'>B</option></select>"
      )
      select = driver.document.query_selector("#s")
      seen = []
      %w[input change].each { |type| select.add_event_listener(type, ->(e) { seen << e.type }) }

      driver.find_css("option[value='b']").first.select_option

      expect(select.value).to eq("b")
      expect(seen).to eq(%w[input change])
    end

    it "send_keys dispatches real keyboard events and inserts the text" do
      driver = js_driver_for("<input id='q'>")
      node = driver.find_css("#q").first
      seen = []
      %w[keydown keypress keyup].each do |type|
        node.native.add_event_listener(type, ->(e) { seen << [e.type, e.__js_get__("key")] })
      end

      node.send_keys("ab")

      expect(node.native.value).to eq("ab")
      expect(seen).to eq([
        %w[keydown a], %w[keypress a], %w[keyup a],
        %w[keydown b], %w[keypress b], %w[keyup b]
      ])
    end
  end

  describe "scripts" do
    it "delegates execute_script and evaluate_script to the runtime" do
      driver = js_driver_for("<p>x</p>")

      driver.execute_script("doIt()")
      result = driver.evaluate_script("1 + 1")

      runtime = @runtimes.last
      expect(runtime.executed).to include("doIt()")
      expect(runtime.evaluated).to include("1 + 1")
      expect(result).to eq("evaluated:1 + 1")
    end

    it "rejects script arguments (not supported)" do
      driver = js_driver_for("<p>x</p>")

      expect { driver.execute_script("f()", 1) }.to raise_error(ArgumentError)
      expect { driver.evaluate_script("f()", 1) }.to raise_error(ArgumentError)
    end
  end

  describe "lifecycle" do
    it "disposes the rack session on reset!" do
      driver = js_driver_for("<p>x</p>")
      session = driver.rack_session

      expect(session).to receive(:dispose).and_call_original
      driver.reset!

      expect(driver.rack_session).not_to be(session)
    end

    it "disposes the old rack session when the effective host changes" do
      driver = js_driver_for("<p>x</p>")
      first = driver.rack_session

      expect(first).to receive(:dispose).and_call_original
      allow(driver).to receive(:effective_host).and_return("http://other.example")

      expect(driver.rack_session).not_to be(first)
    end
  end
end
