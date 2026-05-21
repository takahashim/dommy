# frozen_string_literal: true

# Entry point for using Dommy from Minitest test suites.
# Loads the test helpers and DOM assertion modules so users can
# `include` them into their test classes.
#
# @example
#   require "dommy/minitest"
#
#   class MyTest < Minitest::Test
#     include Dommy::TestHelpers
#     include Dommy::Minitest::Assertions
#   end

require "dommy"
require "dommy/test_helpers"
require "dommy/minitest/assertions"
