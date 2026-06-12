module Dommy
  module Rails
    module TurboStream
      module_function

      def parse(body)
        doc = Dommy.parse(body).document
        doc.query_selector_all("turbo-stream").to_a
      end

      def matches?(body, action:, target:)
        streams = parse(body)
        streams.any? { |s| s.get_attribute("action") == action.to_s && s.get_attribute("target") == target.to_s }
      end

      def fragment_for(body, action:, target:)
        streams = parse(body)
        stream = streams.find { |s| s.get_attribute("action") == action.to_s && s.get_attribute("target") == target.to_s }
        stream ? stream.query_selector("template")&.inner_html : nil
      end

      def fragment_document_for(body, action:, target:)
        fragment = fragment_for(body, action: action, target: target)
        fragment ? Dommy.parse(fragment).document : nil
      end
    end
  end
end
