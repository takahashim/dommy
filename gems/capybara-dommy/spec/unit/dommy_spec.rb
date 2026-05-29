# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy do
  it "has a version number" do
    expect(Capybara::Dommy::VERSION).not_to be_nil
  end

  it "registers the :dommy driver" do
    app = ->(_env) { [200, {"Content-Type" => "text/html"}, ["<p>ok</p>"]] }
    session = Capybara::Session.new(:dommy, app)
    expect(session.driver).to be_an_instance_of(Capybara::Dommy::Driver)
  end
end
