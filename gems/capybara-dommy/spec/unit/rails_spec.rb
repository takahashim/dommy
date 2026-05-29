# frozen_string_literal: true

require "spec_helper"
require "capybara/dommy/rails"

RSpec.describe "capybara/dommy/rails" do
  it "registers the :dommy driver" do
    app = ->(_env) { [200, {"Content-Type" => "text/html"}, ["<h1>Hi</h1>"]] }
    session = Capybara::Session.new(:dommy, app)
    expect(session.driver).to be_an_instance_of(Capybara::Dommy::Driver)
    session.visit("/")
    expect(session.has_selector?("h1", text: "Hi")).to be(true)
  end
end
