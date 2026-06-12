# frozen_string_literal: true

begin
  require "rspec/expectations"
rescue LoadError => e
  raise LoadError, "dommy-rails RSpec integration requires rspec-expectations. Add `gem \"rspec\"` or `gem \"rspec-expectations\"` to your Gemfile.", e.backtrace
end

require "dommy/rspec/capy_style_matchers"
require_relative "../rails"
require_relative "rspec/matchers"
require_relative "rspec/integration"
