# frozen_string_literal: true

# Heavy harness for the Capybara driver compliance suite. Pulls in Capybara's
# shared spec helper and its bundled Sinatra TestApp. Required only by the
# compliance specs, so spec/unit stays lightweight.

require "spec_helper"
require "capybara/spec/spec_helper"

# Sinatra 4 enables host authorization by default, which 403s the
# www.example.com host Capybara uses. Disable it for the bundled TestApp
# (must happen before the first request builds the middleware stack).
if defined?(TestApp) && TestApp.respond_to?(:host_authorization)
  TestApp.set(:host_authorization, permitted_hosts: [])
end

Capybara.register_driver(:dommy) do |app|
  Capybara::Dommy::Driver.new(app, default_host: Capybara.default_host)
end

RSpec.configure do |config|
  Capybara::SpecHelper.configure(config)
end
