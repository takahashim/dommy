# frozen_string_literal: true

require "capybara/dommy"

# Thin convenience layer: registers the :dommy driver so Rails system tests
# can use `driven_by :dommy`. Driver defaults come from
# Capybara::Dommy.configuration.
Capybara.register_driver(:dommy) do |app|
  Capybara::Dommy::Driver.new(app)
end
