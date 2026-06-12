# frozen_string_literal: true

module Dommy
  module Rails
    module TurboStream
      module_function

      def parse(body)
        Dommy.parse(body).document.query_selector_all("turbo-stream").to_a
      end

      def find(body, action:, target:)
        parse(body).find do |stream|
          stream.get_attribute("action") == action.to_s && stream.get_attribute("target") == target.to_s
        end
      end

      def matches?(body, action:, target:)
        !find(body, action: action, target: target).nil?
      end

      # The <template> payload of a stream element, parsed as its own
      # document (nil when the stream has no template).
      def fragment_document(stream)
        fragment = stream.query_selector("template")&.inner_html
        fragment ? Dommy.parse(fragment).document : nil
      end

      def fragment_for(body, action:, target:)
        stream = find(body, action: action, target: target)
        stream ? stream.query_selector("template")&.inner_html : nil
      end

      def fragment_document_for(body, action:, target:)
        stream = find(body, action: action, target: target)
        stream ? fragment_document(stream) : nil
      end
    end
  end
end
