# frozen_string_literal: true

# Entry point for using Dommy from RSpec test suites.
# Loads the test helpers and DOM matcher modules so users can
# `include` them into their RSpec config.
#
# @example
#   require "dommy/rspec"
#
#   RSpec.configure do |c|
#     c.include Dommy::TestHelpers
#     c.include Dommy::RSpec::Matchers
#   end

require "dommy"
require "dommy/test_helpers"
require "dommy/rspec/matchers"
require "dommy/rspec/capy_style_matchers"
