# frozen_string_literal: true

module Capybara
  module Dommy
    # Base error for capybara-dommy. Element lookup failures surface as
    # Capybara's own ElementNotFound / Ambiguous from the finder layer, and
    # unsupported-URL / cross-origin errors propagate from dommy-rack.
    class Error < StandardError; end

    # Raised when a node is used after its element left the current document
    # (e.g. after navigation). Listed in Driver#invalid_element_errors so
    # Capybara reloads and retries.
    class StaleElementReferenceError < Error; end
  end
end
