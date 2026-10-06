# frozen_string_literal: true

require_relative "post_insertion_steps"

module Dommy
  module Internal
    # Coordinates mutation notification: MutationObserver records, and the
    # custom element reactions a mutation triggers. Isolates both from
    # Document's public API. The element behaviours an insertion also sets off —
    # a script running, a details group settling — are PostInsertionSteps'.
    #
    # The custom element reactions are enqueued (Internal::CEReactions), not
    # run: they run when the [CEReactions] member that made the mutation
    # returns, or from the backup element queue.
    class MutationCoordinator
      def initialize(document, observer_manager)
        @document = document
        @observer_manager = observer_manager
        @post_insertion_steps = PostInsertionSteps.new(document, method(:report_exception))
      end


      def register_observer(observer)
        @observer_manager.register(observer)
        nil
      end

      def unregister_observer(observer)
        @observer_manager.unregister(observer)
        nil
      end

      # DOM insert step 7.7 for one connected element: a custom element gets
      # a connectedCallback reaction; any other is tried for an upgrade.
      def notify_connected(element)
        return unless element.respond_to?(:__internal_ce_custom__?)

        registry = element.__internal_ce_registry__
        registry.__internal_note_scoped_document__(element.owner_document) if registry&.scoped?

        if element.__internal_ce_custom__?
          CEReactions.enqueue_callback(element, "connectedCallback", [])
        else
          @document.__internal_try_to_upgrade__(element)
        end
      end

      # DOM remove step 15: a custom element gets a disconnectedCallback
      # reaction.
      def notify_disconnected(element)
        return unless element.respond_to?(:__internal_ce_custom__?) && element.__internal_ce_custom__?

        CEReactions.enqueue_callback(element, "disconnectedCallback", [])
      end

      # Connected callbacks, connected scripts and blank-iframe loads for every
      # element among the subtree's shadow-including inclusive descendants, in
      # shadow-including tree order — so the custom elements in an inserted
      # host's shadow tree connect too.
      def notify_connected_subtree(nk)
        each_shadow_including_element(nk) do |element|
          notify_connected(element)
          @post_insertion_steps.connected(element)
        end
      end



      # WHATWG "move": each custom element among the moved node's
      # shadow-including inclusive descendants, in shadow-including tree order,
      # gets connectedMoveCallback. The caller checks that the new parent is
      # connected.
      def notify_moved_subtree(nk)
        each_shadow_including_element(nk) { |element| notify_moved(element) }
      end

      # HTML's removing steps — the focus fixup, a popover hiding, a dialog
      # leaving the top layer — and the disconnected callbacks, over the same
      # shadow-including walk.
      def notify_disconnected_subtree(nk)
        root = @document.wrap_node(nk)
        @document.__internal_focused_subtree_removed__(root) if root
        each_shadow_including_element(nk) do |element|
          element.__internal_popover_removed__ if element.respond_to?(:__internal_popover_removed__)
          element.__internal_dialog_removed__ if element.respond_to?(:__internal_dialog_removed__)
          notify_disconnected(element)
        end
      end

      # DOM "handle attribute changes" step 2: a custom element gets an
      # attributeChangedCallback reaction (enqueued only when its definition
      # observes the attribute — matched exactly, so a `fooBar` made by
      # setAttributeNS is observed as "fooBar" alone).
      def notify_attribute_changed(element, name, old_value, new_value, namespace = nil)
        return unless element.respond_to?(:__internal_ce_custom__?) && element.__internal_ce_custom__?

        CEReactions.enqueue_callback(element, "attributeChangedCallback", [name.to_s, old_value, new_value, namespace])
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

        # The form-associated custom elements moved in or out reset their form
        # owner and disabled state (their insertion / removing steps), ahead
        # of their connected / disconnected reactions.
        if FormAssociatedCustomElements.any?
          removed_nodes.each { |nk| FormAssociatedCustomElements.refresh_subtree(@document, nk) }
          added_nodes.each { |nk| FormAssociatedCustomElements.refresh_subtree(@document, nk) }
        end

        # Custom Element connected/disconnected callbacks, script execution, and
        # blank-iframe load all require the subtree to be connected to the
        # document (the script/iframe paths already check is_connected?, and
        # connectedCallback fires only when connected). So skip the O(subtree)
        # walk for mutations within a still-detached tree — the common case
        # during bulk DOM construction, where nothing in the walk can fire.
        if !moving && (!target.respond_to?(:is_connected?) || target.is_connected?)
          # A script's children changed steps run before the post-connection
          # steps of what was inserted into it (DOM "insert" orders them so).
          # Only for an insertion: DOM runs them for a removal too, but no
          # browser prepares a script because a child left it, and WPT's
          # script-does-not-run-on-child-removal holds them to that.
          @post_insertion_steps.script_children_changed(target) unless added_nodes.empty?
          # A replacement removes before it inserts (DOM "replace all"), so the
          # disconnected reactions are enqueued ahead of the connected ones.
          removed_nodes.each { |nk| notify_disconnected_subtree(nk) }
          added_nodes.each { |nk| notify_connected_subtree(nk) }
        end

        # HTML's details insertion steps run wherever the element lands, not only
        # in a connected tree, so an accordion group assembled off-document is
        # already consistent by the time it is attached.
        @post_insertion_steps.details_inserted(added_nodes)
        @post_insertion_steps.select_mutated(target_node, added_nodes, removed_nodes)
        connected = target.respond_to?(:is_connected?) && target.is_connected?
        @post_insertion_steps.radios_moved(added_nodes, connected: connected && !moving)
        @post_insertion_steps.radios_moved(removed_nodes, connected: false)
        # HTML's "children changed steps" for the one element that has its own
        # (a pristine textarea's raw value follows its child text content).
        target.__internal_children_changed__(added_nodes, removed_nodes) if target.is_a?(HTMLTextAreaElement)

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

        # Queue this mutation before running attribute change steps: those may
        # mutate another attribute (input type changes can copy value to its
        # content attribute), whose record must follow the originating write.
        # Every attribute API reaches this hook, including the NS variants.
        target.__internal_attribute_changed__(attr, old_value, new_value, namespace) if
          target.respond_to?(:__internal_attribute_changed__)

        notify_attribute_changed(target, attr, old_value, new_value, namespace)
        form_association_attribute_changed(target, target_node, attr) if namespace.nil? && FormAssociatedCustomElements.any?
        @post_insertion_steps.script_attribute_changed(target, attr, new_value, namespace)
        # An event handler content attribute (`onclick="…"`) sets or removes
        # its handler.
        EventHandlers.attribute_changed(target, attr, new_value, namespace) if attr.start_with?("on") && target.is_a?(Element)

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


      # A `form` or `disabled` attribute of a form-associated custom element,
      # a fieldset's `disabled`, or any `id` (a form's, which a `form`
      # attribute names) can change the form owner or the disabled state.
      def form_association_attribute_changed(target, target_node, attr)
        case attr
        when "form" then FormAssociatedCustomElements.refresh(target)
        when "disabled" then FormAssociatedCustomElements.refresh_subtree(@document, target_node)
        when "id" then FormAssociatedCustomElements.refresh_subtree(@document, @document.backend_doc)
        end
      end

      # DOM move: a custom element gets a connectedMoveCallback reaction
      # (CEReactions turns it into disconnected + connected for a definition
      # without one).
      def notify_moved(element)
        return unless element.respond_to?(:__internal_ce_custom__?) && element.__internal_ce_custom__?

        CEReactions.enqueue_callback(element, "connectedMoveCallback", [])
      end
    end
  end
end
