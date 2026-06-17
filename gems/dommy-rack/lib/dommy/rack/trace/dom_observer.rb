# frozen_string_literal: true

module Dommy
  module Rack
    class Trace
      # Watches a window's DOM through a MutationObserver and turns raw mutation
      # records into compact summaries ({op:, target:, count:/attr:}). Pure
      # translation: it holds no event stream and decides nothing about ordering
      # or coalescing — each summary is handed to the block the Trace supplies,
      # which records it. Inert (observes nothing) when the window has no <body>.
      class DomObserver
        def initialize(window, &on_summary)
          @on_summary = on_summary
          body = window&.document&.body
          return unless body

          @observer = Dommy::MutationObserver.new(window, method(:deliver))
          # `observe` is the observer's JS-bridge entry point (Ruby-private), so
          # drive it through the public bridge call.
          @observer.__js_call__("observe",
            [body, {childList: true, subtree: true, attributes: true, characterData: true}])
        end

        private

        def deliver(records, _observer)
          records.each do |record|
            summary = summarize(record)
            @on_summary.call(summary) if summary
          end
          nil
        end

        def summarize(record)
          case record.type
          when "childList"
            if node_count(record.added_nodes).positive?
              {op: :added, target: node_label(record.target), count: node_count(record.added_nodes)}
            elsif node_count(record.removed_nodes).positive?
              {op: :removed, target: node_label(record.target), count: node_count(record.removed_nodes)}
            end
          when "attributes"
            {op: :attr, target: node_label(record.target), attr: record.attribute_name}
          when "characterData"
            {op: :text, target: node_label(record.target)}
          end
        end

        def node_label(node)
          return node.to_s unless node.respond_to?(:tag_name) && node.tag_name

          label = node.tag_name.downcase
          id = node.respond_to?(:get_attribute) ? node.get_attribute("id") : nil
          label += "##{id}" if present?(id)
          klass = node.respond_to?(:get_attribute) ? node.get_attribute("class") : nil
          label += ".#{klass.split.join(".")}" if present?(klass)
          label
        end

        def node_count(list)
          return 0 if list.nil?
          return list.length if list.respond_to?(:length)
          return list.size if list.respond_to?(:size)

          0
        end

        def present?(value) = !(value.nil? || value.to_s.empty?)
      end
    end
  end
end
