# frozen_string_literal: true

module Dommy
  module Internal
    # Coordinates mutation notification to observers and custom element lifecycle callbacks.
    # Isolates mutation observation and custom element logic from Document's public API.
    class MutationCoordinator
      def initialize(document, observer_manager)
        @document = document
        @observer_manager = observer_manager
      end

      def register_observer(observer)
        @observer_manager.register(observer)
        nil
      end

      def unregister_observer(observer)
        @observer_manager.unregister(observer)
        nil
      end

      # Fire CustomElement lifecycle: connected (synchronous, before mutation delivery)
      def notify_connected(element)
        return unless element&.respond_to?(:connected_callback)

        element.connected_callback
      rescue StandardError
        nil
      end

      def notify_disconnected(element)
        return unless element&.respond_to?(:disconnected_callback)

        element.disconnected_callback
      rescue StandardError
        nil
      end

      # Walk a subtree and fire connected/disconnected callbacks for all elements
      def notify_connected_subtree(nk)
        return unless nk.respond_to?(:element?)

        if nk.element?
          wrapped = @document.wrap_node(nk)
          notify_connected(wrapped) if wrapped
        end

        nk.children.each { |c| notify_connected_subtree(c) } if nk.respond_to?(:children)
      end

      def notify_disconnected_subtree(nk)
        return unless nk.respond_to?(:element?)

        if nk.element?
          wrapped = @document.wrap_node(nk)
          notify_disconnected(wrapped) if wrapped
        end

        nk.children.each { |c| notify_disconnected_subtree(c) } if nk.respond_to?(:children)
      end

      def notify_attribute_changed(element, name, old_value, new_value)
        return unless element&.respond_to?(:attribute_changed_callback)

        klass = element.class
        return unless klass.respond_to?(:observed_attributes)
        return unless klass.observed_attributes.include?(name.to_s.downcase)

        element.attribute_changed_callback(name, old_value, new_value)
      rescue StandardError
        nil
      end

      # Fire MutationObserver childList records
      def notify_child_list_mutation(
        target_node:,
        added_nodes:,
        removed_nodes:,
        previous_sibling: nil,
        next_sibling: nil
      )
        target = @document.wrap_node(target_node)
        return nil unless target
        return nil if added_nodes.empty? && removed_nodes.empty?

        wrapped_added = added_nodes.map { |node| @document.wrap_node(node) }.compact
        wrapped_removed = removed_nodes.map { |node| @document.wrap_node(node) }.compact

        # Fire Custom Element lifecycle callbacks (synchronous, before MutationObserver microtask)
        added_nodes.each { |nk| notify_connected_subtree(nk) }
        removed_nodes.each { |nk| notify_disconnected_subtree(nk) }

        # Capture previousSibling / nextSibling (the position within target)
        prev_w = previous_sibling
        next_w = next_sibling
        if (prev_w.nil? && next_w.nil?) && !added_nodes.empty?
          first_nk = added_nodes.first
          last_nk = added_nodes.last
          prev_w ||= @document.wrap_node(first_nk.previous) if first_nk.respond_to?(:previous)
          next_w ||= @document.wrap_node(last_nk.next) if last_nk.respond_to?(:next)
        end

        record = MutationRecord.new(
          type: "childList",
          target: target,
          added_nodes: wrapped_added,
          removed_nodes: wrapped_removed,
          previous_sibling: prev_w,
          next_sibling: next_w
        )
        @observer_manager.observers_matching(target).each do |observer|
          observer.enqueue(record)
        end

        nil
      end

      # Fire MutationObserver attribute records
      def notify_attribute_mutation(target_node:, attribute_name:, old_value:)
        target = @document.wrap_node(target_node)
        return nil unless target

        attr = attribute_name.to_s.downcase
        new_value = target_node[attr]

        # Custom Element attributeChangedCallback (synchronous)
        notify_attribute_changed(target, attr, old_value, new_value)

        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry && entry[:attributes]

          filter = entry[:attribute_filter]
          next if filter && !filter.include?(attr)

          observer.enqueue(
            MutationRecord.new(
              type: "attributes",
              target: target,
              attribute_name: attr,
              old_value: entry[:attribute_old_value] ? old_value : nil
            )
          )
        end

        nil
      end

      # Fire MutationObserver characterData records
      def notify_character_data_mutation(target_node:, old_value:)
        target = @document.wrap_node(target_node)
        return nil unless target

        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry && entry[:character_data]

          observer.enqueue(
            MutationRecord.new(
              type: "characterData",
              target: target,
              old_value: entry[:character_data_old_value] ? old_value : nil
            )
          )
        end

        nil
      end
    end
  end
end
