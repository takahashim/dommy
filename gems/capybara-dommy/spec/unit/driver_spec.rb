# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy::Driver do
  it "tracks current_url after a visit" do
    driver = driver_for("<h1>Hi</h1>")
    expect(driver.current_url).to eq("http://example.org/")
  end

  it "raises on an unknown visibility mode" do
    expect {
      Capybara::Dommy::Driver.new(html_app("<h1>Hi</h1>"), visibility: :bogus)
    }.to raise_error(ArgumentError)
  end

  it "serializes the document via #html" do
    driver = driver_for("<h1>Hi</h1>")
    expect(driver.html).to include("<h1>Hi</h1>")
  end

  it "exposes the status code" do
    driver = Capybara::Dommy::Driver.new(->(_env) { [201, {"Content-Type" => "text/html"}, ["<p>x</p>"]] })
    driver.visit("/")
    expect(driver.status_code).to eq(201)
  end

  it "exposes response headers" do
    driver = Capybara::Dommy::Driver.new(
      ->(_env) { [200, {"Content-Type" => "text/html", "X-Custom" => "yes"}, ["<p>x</p>"]] }
    )
    driver.visit("/")
    expect(driver.response_headers["X-Custom"]).to eq("yes")
  end

  it "returns nodes from find_css" do
    driver = driver_for('<ul><li class="x">a</li><li class="x">b</li></ul>')
    nodes = driver.find_css(".x")
    expect(nodes.size).to eq(2)
    expect(nodes.first).to be_an_instance_of(Capybara::Dommy::Node)
  end

  it "returns nodes from find_xpath" do
    driver = driver_for("<ul><li>a</li><li>b</li></ul>")
    expect(driver.find_xpath("//li").size).to eq(2)
  end

  it "clears the session on reset!" do
    driver = driver_for("<h1>Hi</h1>")
    driver.rack_session.set_cookie("k", "v")
    driver.reset!
    expect(driver.rack_session.get_cookie("k")).to be_nil
  end

  it "does not support JavaScript" do
    driver = driver_for("<h1>Hi</h1>")
    expect { driver.execute_script("1") }.to raise_error(Capybara::NotSupportedByDriverError)
    expect { driver.evaluate_script("1") }.to raise_error(Capybara::NotSupportedByDriverError)
    expect { driver.evaluate_async_script("1") }.to raise_error(Capybara::NotSupportedByDriverError)
  end

  it "treats JavaScript as a no-op when raising is disabled" do
    Capybara::Dommy.configure { |c| c.raise_on_unsupported_js = false }
    driver = driver_for("<h1>Hi</h1>")
    expect(driver.execute_script("1")).to be_nil
    expect(driver.evaluate_script("1")).to be_nil
  ensure
    Capybara::Dommy.reset_configuration!
  end

  it "navigates back and forward" do
    app = app_for(
      "GET /one" => html_response("<h1>One</h1>"),
      "GET /two" => html_response("<h1>Two</h1>")
    )
    driver = Capybara::Dommy::Driver.new(app)
    driver.visit("/one")
    driver.visit("/two")
    driver.go_back
    expect(URI.parse(driver.current_url).path).to eq("/one")
    driver.go_forward
    expect(URI.parse(driver.current_url).path).to eq("/two")
  end
end
