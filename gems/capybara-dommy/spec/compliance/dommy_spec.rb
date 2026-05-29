# frozen_string_literal: true

require_relative "compliance_helper"

module TestSessions
  Dommy = Capybara::Session.new(:dommy, TestApp)
end

# Capabilities capybara-dommy genuinely does not provide (no JavaScript,
# no layout/rendering, no real browser server). Behavioral differences are
# fixed across dommy / dommy-rack / capybara-dommy rather than skipped.
skipped_tests = %i[
  js
  modals
  windows
  frames
  screenshot
  send_keys
  css
  scroll
  spatial
  shadow_dom
  active_element
  hover
  html_validation
  download
  about_scheme
  server
]

Capybara::SpecHelper.run_specs(TestSessions::Dommy, "Dommy", capybara_skip: skipped_tests) do |example|
  case example.metadata[:full_description]
  when /has_css\? should support case insensitive :class and :id options/
    skip "Nokogiri doesn't support case insensitive CSS attribute matchers (same as RackTest)"
  end
end
