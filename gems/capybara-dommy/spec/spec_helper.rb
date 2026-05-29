# frozen_string_literal: true

# Lightweight helper loaded for every spec (via .rspec --require spec_helper).
# It intentionally does NOT pull in Capybara's compliance harness or boot the
# Sinatra TestApp, so the unit specs under spec/unit run fast and standalone.
# The heavy machinery lives in spec/compliance/compliance_helper.rb.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "capybara/dommy"

require_relative "support/dommy_helper"

Capybara.register_driver(:dommy) { |app| Capybara::Dommy::Driver.new(app) }

# When the compliance suite is loaded in the same process it installs a global
# before-hook (Capybara::SpecHelper.reset!) that flips Capybara to :xpath and
# TestApp. Our unit specs assume Capybara's stock defaults, so re-assert them
# via a group-level hook — which runs after any config-level before-hook.
module DommyUnitDefaults
  def self.included(group)
    group.before do
      Capybara.default_selector = :css
      Capybara.app = nil
    end
  end
end

RSpec.configure do |config|
  config.include CapybaraDommyTestHelper
  config.include DommyUnitDefaults, file_path: %r{spec/unit/}
end
