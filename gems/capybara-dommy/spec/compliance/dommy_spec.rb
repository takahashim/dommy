# frozen_string_literal: true

require_relative "compliance_helper"

module TestSessions
  Dommy = Capybara::Session.new(:dommy, TestApp)
end

# Capabilities capybara-dommy genuinely does not provide (no JavaScript,
# no layout/rendering, no real browser server). Behavioral differences are
# fixed across dommy / dommy-rack / capybara-dommy rather than skipped.
#
# Verified against the makiri backend (2026-06-12): with every group enabled
# the suite has 370 failures, all attributable to these capabilities. The
# closest-to-passing groups still fail on real gaps: shadow_dom (Node#path
# inside a shadow tree), html_validation (constraint-validation
# validationMessage), about_scheme (visiting non-http URLs).
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

Capybara::SpecHelper.run_specs(TestSessions::Dommy, "Dommy", capybara_skip: skipped_tests)
