# frozen_string_literal: true

require "capybara/dommy"

# Thin convenience layer: registers the :dommy driver so Rails system tests
# can use `driven_by :dommy`. Driver defaults come from
# Capybara::Dommy.configuration.
Capybara.register_driver(:dommy) do |app|
  Capybara::Dommy::Driver.new(app)
end

# The JavaScript-enabled variant (`driven_by :dommy_js`): pages run their real
# Turbo/Stimulus/React bundles in the embedded QuickJS runtime, no browser
# process. Requires dommy-js-quickjs.
Capybara.register_driver(:dommy_js) do |app|
  Capybara::Dommy::Driver.new(app, javascript: true)
end
