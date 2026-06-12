# frozen_string_literal: true

module Dommy
  # The shared, JS-engine-independent interaction layer: locating elements,
  # driving form fields, synthesizing DOM event sequences, serializing form
  # submissions, and query matchers. `Dommy::Rack::Session` (Rack-backed) and
  # `Dommy::Browser` (standalone, JS-enabled) both build on it so the Capybara
  # vocabulary lives in one place.
  module Interaction
    class Error < StandardError; end

    # Raised when a locator matches no element.
    class ElementNotFoundError < Error; end

    # Raised when a locator matches more than one element.
    class AmbiguousElementError < Error; end

    # Raised when a file to be uploaded does not exist.
    class FileNotFoundError < Error; end
  end
end

require_relative "interaction/event_synthesis"
require_relative "interaction/locator"
require_relative "interaction/field_interactor"
require_relative "interaction/form_submission"
require_relative "interaction/driver"
