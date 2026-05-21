# frozen_string_literal: true

module Dommy
  module Internal
    # Resolve various subject types into a uniform DOM scope for
    # matchers and assertions to operate on.
    #
    # Test helpers want to let callers pass whatever they have on hand
    # — `rendered`, `response.body`, a Document, an Element — and have
    # it Just Work. This module centralizes that conversion so the
    # matchers themselves stay focused on matching logic.
    module ScopeResolution
      module_function

      # Convert the given subject into a scope usable by query_selector
      # / text_content / inner_html.
      #
      # - String: parsed as HTML (full document or body fragment, per
      #   `Dommy.parse`)
      # - Anything else: returned as-is (Document, Element, Fragment,
      #   ShadowRoot, etc.)
      def resolve(scope)
        scope.is_a?(String) ? Dommy.parse(scope).document : scope
      end
    end
  end
end
