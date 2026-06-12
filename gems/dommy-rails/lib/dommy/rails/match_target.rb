# frozen_string_literal: true

module Dommy
  module Rails
    # Resolves the objects assertions/matchers accept (response-like,
    # raw HTML string, or an already-parsed Dommy document/element)
    # into a document or body string.
    module MatchTarget
      module_function

      def document(actual)
        return actual.document if actual.respond_to?(:document)
        return actual if actual.respond_to?(:query_selector_all)

        Dommy.parse(body(actual)).document
      end

      def body(actual)
        actual.respond_to?(:body) ? actual.body.to_s : actual.to_s
      end
    end
  end
end
