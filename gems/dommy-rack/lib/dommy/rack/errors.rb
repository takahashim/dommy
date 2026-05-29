# frozen_string_literal: true

module Dommy
  module Rack
    class Error < StandardError; end

    # Raised when a locator matches no element.
    class ElementNotFoundError < Error; end

    # Raised when an element cannot be clicked (e.g. a link with no href).
    class ElementNotClickableError < Error; end

    # Raised when a locator matches more than one element.
    class AmbiguousElementError < Error; end

    # Raised for hrefs that dommy-rack cannot navigate to (javascript:, mailto:, ...).
    class UnsupportedURLError < Error; end

    # Raised when a request would cross origins, which is not allowed.
    class CrossOriginError < Error; end

    # Raised when a redirect chain exceeds max_redirects.
    class TooManyRedirectsError < Error; end

    # Raised when a response content type cannot be handled as requested.
    class UnsupportedContentTypeError < Error; end

    # Raised when a form is malformed or cannot be submitted.
    class InvalidFormError < Error; end

    # Raised when a file to be uploaded does not exist.
    class FileNotFoundError < Error; end
  end
end
