# frozen_string_literal: true

require_relative "compliance_helper"

module TestSessions
  Dommy = Capybara::Session.new(:dommy, TestApp)
end

# Capabilities capybara-dommy genuinely does not provide (no JavaScript,
# no layout/rendering, no real browser server). Behavioral differences are
# fixed across dommy / dommy-rack / capybara-dommy rather than skipped.
#
# shadow_dom stays skipped not for the capability itself but because its
# only spec (Node#path inside a shadow tree) obtains the element via
# evaluate_script, which needs a JS engine.
skipped_tests = %i[
  js
  modals
  windows
  screenshot
  css
  scroll
  spatial
  shadow_dom
  hover
  download
  server
]

Capybara::SpecHelper.run_specs(TestSessions::Dommy, "Dommy", capybara_skip: skipped_tests) do |example|
  case example.metadata[:full_description]
  when /#active_element should support reloading/
    skip "Drives focus from a script via execute_script (needs a JS engine)"
  end
end
