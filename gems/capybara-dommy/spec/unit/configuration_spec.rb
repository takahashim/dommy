# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy::Configuration do
  after { Capybara::Dommy.reset_configuration! }

  it "has the expected defaults" do
    config = Capybara::Dommy::Configuration.new
    expect(config.default_host).to eq("http://example.org")
    expect(config.follow_redirects).to be(true)
    expect(config.max_redirects).to eq(5)
    expect(config.visibility).to eq(:html)
  end

  it "sets values via the configure block" do
    Capybara::Dommy.configure do |config|
      config.default_host = "http://test.example"
      config.visibility = :all
    end
    expect(Capybara::Dommy.configuration.default_host).to eq("http://test.example")
    expect(Capybara::Dommy.configuration.visibility).to eq(:all)
  end

  it "uses configuration defaults when building a driver" do
    Capybara::Dommy.configure do |config|
      config.default_host = "http://configured.test"
      config.visibility = :all
    end
    driver = Capybara::Dommy::Driver.new(html_app("<h1>Hi</h1>"))
    driver.visit("/")
    expect(driver.current_url).to eq("http://configured.test/")
    expect(driver.visibility).to eq(:all)
  end

  it "lets explicit args override configuration" do
    Capybara::Dommy.configure { |c| c.default_host = "http://configured.test" }
    driver = Capybara::Dommy::Driver.new(html_app("<h1>Hi</h1>"), default_host: "http://explicit.test")
    driver.visit("/")
    expect(driver.current_url).to eq("http://explicit.test/")
  end
end
