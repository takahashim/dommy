# frozen_string_literal: true

require "dommy"

module Dommy
  module Rack
    class Error < StandardError; end

    # Locating / ambiguity / file errors ARE the shared interaction errors, so a
    # locator that finds nothing raises the same class whether driven by the
    # Rack session or the standalone Browser. Aliased so existing
    # `Dommy::Rack::X` call sites keep resolving.
    ElementNotFoundError = Dommy::Interaction::ElementNotFoundError
    AmbiguousElementError = Dommy::Interaction::AmbiguousElementError
    FileNotFoundError = Dommy::Interaction::FileNotFoundError

    # Raised when an element cannot be clicked (e.g. a link with no href).
    class ElementNotClickableError < Error; end

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
  end
end
