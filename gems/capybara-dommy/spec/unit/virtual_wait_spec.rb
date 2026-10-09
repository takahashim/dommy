# frozen_string_literal: true

require "spec_helper"
require "support/null_runtime"

# Capybara's wait on a JavaScript-enabled Dommy page is a span of the page's
# virtual time (VirtualWait): a retry moves the clock to the next timer, a
# page that cannot change within the wait fails at once, and only an open
# connection is waited for in real time. Timers here are Ruby callables on
# the page's scheduler, standing in for a page's setTimeout.
RSpec.describe "Waiting on the virtual clock" do
  before do
    @runtimes = []
    @previous_factory = CapybaraDommyJsSupport.install(@runtimes)
    @driver = Capybara::Dommy::Driver.new(html_app('<div id="root"></div>'), javascript: true)
    Capybara.register_driver(:dommy_virtual_wait_test) { |_app| @driver }
    @page = Capybara::Session.new(:dommy_virtual_wait_test, nil)
    @page.visit("/")
  end

  after do
    CapybaraDommyJsSupport.restore(@previous_factory)
  end

  def session = @driver.rack_session
  def document = session.document
  def scheduler = document.default_view.scheduler

  def later(ms, &block)
    scheduler.set_timeout(block, ms)
  end

  def add(id, text = "")
    element = document.create_element("p")
    element.id = id
    element.text_content = text
    document.get_element_by_id("root").append_child(element)
  end

  def real_time
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  it "moves the clock to the next timer rather than polling in real time" do
    later(300) { add("results") }

    elapsed = real_time { expect(@page).to have_css("#results", wait: 2) }

    expect(elapsed).to be < 0.1
    expect(session.virtual_time).to be_between(300, 400)
  end

  it "still sees a state that a later timer takes away" do
    add("spinner")
    later(300) { document.get_element_by_id("spinner").remove }

    expect(@page).to have_css("#spinner")
    expect(@page).to have_no_css("#spinner", wait: 2)
  end

  it "fails at once when nothing within the wait can change the page" do
    add("present")

    elapsed = real_time do
      expect { expect(@page).to have_no_css("#present", wait: 2) }.to raise_error(RSpec::Expectations::ExpectationNotMetError)
    end

    expect(elapsed).to be < 0.1
  end

  it "does not reach a timer due after the wait, and fails without waiting for it" do
    fired = false
    later(5_000) { fired = true }

    elapsed = real_time do
      expect { @page.find("#never", wait: 0.2) }.to raise_error(Capybara::ElementNotFound)
    end

    expect(elapsed).to be < 0.1
    expect(fired).to be(false)
    expect(session.virtual_time).to be < 5_000
  end

  # Each attempt's frame counts too: with timers at 200 and 310 ms and a
  # 300 ms wait, the second is beyond the wait once the frames are counted.
  it "counts the frame of every attempt against the wait" do
    later(200) { add("first") }
    fired = false
    later(310) { fired = true }

    expect { @page.find("#never", wait: 0.3) }.to raise_error(Capybara::ElementNotFound)
    expect(@page).to have_css("#first", wait: 0)
    expect(fired).to be(false)
  end

  it "takes wait: false as no wait" do
    add("button")

    expect { @page.find("#button").click(wait: false) }.not_to raise_error
    later(100) { add("late") }
    expect(@page).to have_no_css("#late", wait: false)
    expect(@page).to have_css("#late", wait: 1)
  end

  it "tries once more after a reload when a node went stale" do
    add("item", "old")
    node = @page.find("#item")
    document.get_element_by_id("item").remove
    add("item", "new")

    expect(node.text).to eq("new")
  end

  # A worker fetch: in flight until the worker posts its completion back.
  def fetch_on_a_worker(after:, &deliver)
    scheduler.begin_external_work
    Thread.new do
      sleep after
      scheduler.post_external(&deliver)
    ensure
      scheduler.end_external_work
    end
  end

  it "waits in real time for a fetch on a worker, before a later timer" do
    fetch_on_a_worker(after: 0.05) { add("loaded") }
    timed_out = false
    later(100) { timed_out = true }

    expect(@page).to have_css("#loaded", wait: 2)
    expect(timed_out).to be(false)
  end

  it "delivers a completion handed back to a frame's realm" do
    document.get_element_by_id("root").inner_html = "<iframe></iframe>"
    frame = document.query_selector("iframe").content_window
    session.instance_variable_get(:@js_runtime).runtime_for(frame.document)
    frame.scheduler.post_external { add("from-frame") }

    elapsed = real_time { expect(@page).to have_css("#from-frame", wait: 2) }

    expect(elapsed).to be < 0.1
  end

  it "runs a frame's timer within the wait" do
    document.get_element_by_id("root").inner_html = "<iframe></iframe>"
    frame = document.query_selector("iframe").content_window
    session.instance_variable_get(:@js_runtime).runtime_for(frame.document)
    frame.scheduler.set_timeout(-> { add("from-frame-timer") }, 300)

    expect(@page).to have_css("#from-frame-timer", wait: 2)
  end

  it "waits in real time only while a connection is open" do
    allow(session).to receive(:open_connections?).and_return(true)

    elapsed = real_time do
      expect { @page.find("#never", wait: 0.2) }.to raise_error(Capybara::ElementNotFound)
    end

    expect(elapsed).to be_between(0.2, 1.0)
  end

  it "does not spin on a timer that keeps re-arming itself" do
    rearm = nil
    rearm = -> { later(0, &rearm) }
    rearm.call

    elapsed = real_time do
      expect { @page.find("#never", wait: 0.2) }.to raise_error(Capybara::ElementNotFound)
    end

    expect(elapsed).to be < 0.5
  end

  it "leaves a driver without JavaScript to Capybara's loop" do
    driver = Capybara::Dommy::Driver.new(html_app("<p>x</p>"))
    Capybara.register_driver(:dommy_plain_wait_test) { |_app| driver }
    page = Capybara::Session.new(:dommy_plain_wait_test, nil)
    page.visit("/")

    expect(page).to have_css("p")
    expect(driver.instance_variable_get(:@wait)).to be_nil
  end
end
