# frozen_string_literal: true

require_relative "insertion_steps"

module Dommy
  module Internal
    # Coordinates mutation notification: MutationObserver records, and the
    # custom element reactions a mutation triggers. Isolates both from
    # Document's public API. The element behaviours an insertion also sets off —
    # a script running, a details group settling — are InsertionSteps'.
    #
    # A custom element reaction that throws is the page's exception, so it is
    # REPORTED at the window ("report an exception"), the same seam an event
    # listener's exception takes. It used to be discarded.
    class MutationCoordinator
      def initialize(document, observer_manager)
        @document = document
        @observer_manager = observer_manager
        @insertion_steps = InsertionSteps.new(document, method(:report_exception))
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
      rescue StandardError => e
        report_exception(e)
      end

      def notify_disconnected(element)
        return unless element&.respond_to?(:disconnected_callback)

        element.disconnected_callback
      rescue StandardError => e
        report_exception(e)
      end

      # Connected callbacks, connected scripts and blank-iframe loads for every
      # element among the subtree's shadow-including inclusive descendants, in
      # shadow-including tree order — so the custom elements in an inserted
      # host's shadow tree connect too.
      def notify_connected_subtree(nk)
        each_shadow_including_element(nk) do |element|
          notify_connected(element)
          @insertion_steps.connected(element)
        end
      end



      # WHATWG "move": each custom element among the moved node's
      # shadow-including inclusive descendants, in shadow-including tree order,
      # gets connectedMoveCallback. The caller checks that the new parent is
      # connected.
      def notify_moved_subtree(nk)
        each_shadow_including_element(nk) { |element| notify_moved(element) }
      end

      # Disconnected callbacks, over the same shadow-including walk.
      def notify_disconnected_subtree(nk)
        each_shadow_including_element(nk) { |element| notify_disconnected(element) }
      end

      def notify_attribute_changed(element, name, old_value, new_value, namespace = nil)
        return unless element&.respond_to?(:attribute_changed_callback)

        klass = element.class
        return unless klass.respond_to?(:observed_attributes)
        return unless klass.observed_attributes.include?(name.to_s.downcase)

        # attributeChangedCallback's 4th arg is the attribute's namespace (null
        # for a plain HTML attribute). Pass it only to callbacks that accept it
        # (the JS bridge, or a 4-arg Ruby callback) so existing 3-arg Ruby custom
        # elements keep working.
        cb = element.method(:attribute_changed_callback)
        if cb.arity.negative? || cb.arity >= 4
          element.attribute_changed_callback(name, old_value, new_value, namespace)
        else
          element.attribute_changed_callback(name, old_value, new_value)
        end
      rescue StandardError => e
        report_exception(e)
      end

      # Fire MutationObserver childList records
      # `moving:` marks the records of a move (moveBefore). A move runs neither
      # the insertion nor the removing steps, so the connected / disconnected
      # walk below — lifecycle callbacks, script execution, blank-iframe load —
      # is skipped for it; its custom element reactions are the move's own
      # (notify_moved_subtree).
      def notify_child_list_mutation(
        target_node:,
        added_nodes:,
        removed_nodes:,
        previous_sibling: nil,
        next_sibling: nil,
        moving: false
      )
        @document.__internal_note_tree_mutation__
        target = @document.wrap_node(target_node)
        return nil unless target
        return nil if added_nodes.empty? && removed_nodes.empty?

        # Custom Element connected/disconnected callbacks, script execution, and
        # blank-iframe load all require the subtree to be connected to the
        # document (the script/iframe paths already check is_connected?, and
        # connectedCallback fires only when connected). So skip the O(subtree)
        # walk for mutations within a still-detached tree — the common case
        # during bulk DOM construction, where nothing in the walk can fire.
        if !moving && (!target.respond_to?(:is_connected?) || target.is_connected?)
          added_nodes.each { |nk| notify_connected_subtree(nk) }
          removed_nodes.each { |nk| notify_disconnected_subtree(nk) }
        end

        # HTML's details insertion steps run wherever the element lands, not only
        # in a connected tree, so an accordion group assembled off-document is
        # already consistent by the time it is attached.
        @insertion_steps.details_inserted(added_nodes)
        @insertion_steps.select_mutated(target_node, added_nodes, removed_nodes)

        # MutationRecords are only needed when something is observing; skip the
        # eager wrapping + record entirely when no observer is registered.
        return nil unless @observer_manager.any?

        wrapped_added = added_nodes.map { |node| @document.wrap_node(node) }.compact
        wrapped_removed = removed_nodes.map { |node| @document.wrap_node(node) }.compact

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
        # Only observers whose matching registration requested childList get the
        # record (an `attributes`/`characterData`-only observer must not — e.g.
        # `observe(t, {childList: false, attributes: true})`).
        #
        # The transient registered observers of remove step 20 are added by the
        # removal primitive (`Document#detach_node`), not here: that step is not
        # guarded by suppressObservers, so it must also run for the removals
        # that queue no record.
        @observer_manager.observers_matching_in_order(target, :child_list).each do |observer|
          entry = observer.find_matching_entry(target, type: :child_list)
          next unless entry

          observer.enqueue(record)
        end

        nil
      end

      # Fire MutationObserver attribute records
      def notify_attribute_mutation(target_node:, attribute_name:, old_value:, namespace: nil)
        # The name arrives already resolved: `setAttribute` lower-cases it only
        # when the element is in the HTML namespace AND its node document is an
        # HTML document (its step 2), and the namespace setters pass the local
        # name through. Lower-casing again here would rename an attribute on,
        # say, an SVG element, which keeps `A` as `A`.
        attr = attribute_name.to_s
        @document.__internal_note_attribute_mutation__(attr, target_node)
        target = @document.wrap_node(target_node)
        return nil unless target
        # Namespace-exact: `target_node[attr]` indexes by local name and would
        # answer for a prefixed attribute with the same one.
        new_value = Backend.get_attribute_ns(target_node, namespace, attr)

        # HTML "attribute change steps": an element that reacts to one of its own
        # attributes (a details to `open`, an option to `selected`, a select to
        # `multiple` / `size`) does it here — on EVERY write path, since they all
        # end up announcing the mutation, where overriding `setAttribute` and
        # `removeAttribute` in each class missed `setAttributeNS` and its
        # removal counterpart.
        target.__internal_attribute_changed__(attr, old_value, new_value, namespace) if
          target.respond_to?(:__internal_attribute_changed__)

        # Custom Element attributeChangedCallback (synchronous)
        notify_attribute_changed(target, attr, old_value, new_value, namespace)

        # The attributeFilter is part of the per-registration condition, so it is
        # applied inside `entry_wants?` rather than to the observer as a whole:
        # a filtered registration must not hide another one of the same observer
        # that accepts this attribute.
        @observer_manager.observers_matching_in_order(target, :attributes, attr, namespace)
                         .each do |observer|
          next unless observer.find_matching_entry(target, type: :attributes, name: attr,
                                                           namespace: namespace)

          observer.enqueue(
            MutationRecord.new(
              type: "attributes",
              target: target,
              attribute_name: attr,
              attribute_namespace: namespace,
              old_value: observer.records_old_value?(target, :attributes, attr, namespace) ? old_value : nil
            )
          )
        end

        nil
      end

      # Fire MutationObserver characterData records
      def notify_character_data_mutation(target_node:, old_value:)
        @document.__internal_note_character_data_mutation__(target_node, old_value)
        target = @document.wrap_node(target_node)
        return nil unless target

        @observer_manager.observers_matching_in_order(target, :character_data).each do |observer|
          entry = observer.find_matching_entry(target, type: :character_data)
          next unless entry

          observer.enqueue(
            MutationRecord.new(
              type: "characterData",
              target: target,
              old_value: observer.records_old_value?(target, :character_data) ? old_value : nil
            )
          )
        end

        nil
      end

      private

      # WHATWG "report an exception" for a reaction or a page script that threw.
      # A document with no window has nowhere to report to, so the exception
      # stops here rather than escaping into the mutation that caused it.
      def report_exception(error)
        window = (@document.default_view if @document.respond_to?(:default_view))
        return unless window.respond_to?(:__internal_report_exception__)

        Internal::ExceptionReport.report_at(window, error)
      end

      # The wrapped elements of the document's shadow-including walk.
      def each_shadow_including_element(nk)
        @document.__internal_each_shadow_including_element__(nk) do |element_node|
          wrapped = @document.wrap_node(element_node)
          yield wrapped if wrapped
        end
      end


      # HTML "enqueue a custom element callback reaction": a definition without
      # connectedMoveCallback runs disconnectedCallback and then connectedCallback
      # in its place. (A JS-defined element always answers the Ruby method; the
      # bridge falls back on the JS side.)
      def notify_moved(element)
        if element.respond_to?(:connected_move_callback)
          element.connected_move_callback
        else
          notify_disconnected(element)
          notify_connected(element)
        end
      rescue StandardError => e
        report_exception(e)
      end
    end
  end
end
