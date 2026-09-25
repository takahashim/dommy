# frozen_string_literal: true

module Dommy
  module Interaction
    # A read-only debugging view over a DOM scope (a document or any element),
    # built on DomSummary. `Dommy::Rack::Session` and `Dommy::Browser` expose it
    # as `#debug` (scoped to the current `within`), but it wraps a plain node so
    # it works on any document too — e.g. `Dommy::Interaction::Debug.new(dom)`
    # in a request/view spec.
    #
    #   browser.debug.dom_summary   # readable forms/links/buttons/fields
    #   browser.debug.buttons       # structured [{label:, type:, selector:}]
    class Debug
      def initialize(scope)
        @scope = scope
        @summary = DomSummary.new(scope)
      end

      # A readable, sectioned summary of the visible controls.
      def dom_summary = @summary.to_text

      def forms = @summary.forms
      def links = @summary.links
      def buttons = @summary.buttons
      def fields = @summary.fields

      # The scope's collapsed visible text content.
      def visible_text = @summary.text

      # The accessibility tree / Playwright-compatible ARIA snapshot of the
      # current scope.
      def aria_tree = Internal::AccessibilityTree.build(@scope)
      def aria_snapshot = Internal::AriaSnapshot.serialize(aria_tree)
    end
  end
end
