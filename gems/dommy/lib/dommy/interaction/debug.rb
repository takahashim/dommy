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
      end

      # A readable, sectioned summary of the visible controls.
      def dom_summary = DomSummary.to_text(@scope)

      def forms = DomSummary.forms(@scope)
      def links = DomSummary.links(@scope)
      def buttons = DomSummary.buttons(@scope)
      def fields = DomSummary.fields(@scope)

      # The scope's collapsed visible text content.
      def visible_text = DomSummary.text(@scope)
    end
  end
end
