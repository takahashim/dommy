# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy::Driver, "time pump" do
  it "reports wait? only while a pump is installed" do
    driver = driver_for("<p>hi</p>")
    expect(driver.wait?).to be false

    driver.time_pump = -> {}
    expect(driver.wait?).to be true

    driver.time_pump = nil
    expect(driver.wait?).to be false
  end

  it "invokes the pump before each polled read" do
    driver = driver_for("<p>hi</p>")
    calls = 0
    driver.time_pump = -> { calls += 1 }

    driver.find_css("p")
    driver.find_xpath("//p")
    driver.html
    driver.title
    expect(calls).to eq(4)
  end

  it "survives reset!" do
    driver = driver_for("<p>hi</p>")
    driver.time_pump = -> {}
    driver.reset!
    expect(driver.wait?).to be true
  end

  it "lets Capybara's synchronize loop converge on pumped changes" do
    driver = Capybara::Dommy::Driver.new(html_app("<div id='root'></div>"))
    Capybara.register_driver(:dommy_pump_test) { |_app| driver }
    session = Capybara::Session.new(:dommy_pump_test, nil)
    session.visit("/")

    pumps = 0
    driver.time_pump = lambda do
      pumps += 1
      if pumps == 3
        late = driver.document.create_element("p")
        late.text_content = "late content"
        driver.document.get_element_by_id("root").append_child(late)
      end
    end

    expect(session).to have_css("p", text: "late content", wait: 2)
    expect(pumps).to be >= 3
  end
end
