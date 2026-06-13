# frozen_string_literal: true

require_relative "../browser_spec"

# Opt-in RSpec wiring for browser specs: `require "dommy/rails/rspec/browser"`
# (e.g. in rails_helper), then tag example groups with `type: :browser` to get
# the `browser` helper (a javascript: true session over the Rails app) without
# an explicit `include`. Route URL helpers (`root_path`, …) are included too, so
# browser specs read like request specs.
#
#   RSpec.describe "Todos", type: :browser do
#     it "toggles a todo" do
#       browser.visit root_path
#       browser.click "li.todo"
#       expect(browser).to have_css("li.todo.is-completed")
#     end
#   end
if defined?(::RSpec)
  ::RSpec.configure do |config|
    config.include Dommy::Rails::BrowserSpec, type: :browser

    if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
      config.include ::Rails.application.routes.url_helpers, type: :browser
    end
  end
end
