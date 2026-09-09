# frozen_string_literal: true

require_relative "../browser_spec"
require "dommy/rspec/capy_style_matchers"

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

  # When a matcher fails on a trace-enabled session subject (a browser spec's
  # `expect(browser).to have_text …`), append the current page and a recent
  # trace to the failure message. Subjects without a trace (request/view specs'
  # `expect(dom)`) are left untouched.
  Dommy::RSpec.failure_context = lambda do |subject|
    next nil unless subject.respond_to?(:trace) && subject.trace

    trace = subject.trace
    page = trace.current_page
    "Current page: #{page[:url]} title=#{page[:title].inspect}\n\n" \
      "Recent trace:\n#{trace.to_text(limit: 15)}"
  end
end
