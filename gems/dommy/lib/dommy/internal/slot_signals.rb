# frozen_string_literal: true

module Dommy
  module Internal
    # DOM "signal a slot change": a slot whose assigned nodes changed joins the
    # window's signal slots, and the mutation observer microtask fires
    # `slotchange` at each of them, once, after the MutationObservers' records
    # (Internal::MutationObserverMicrotask).
    #
    # The spec runs "assign slottables for a tree" at each mutation that can
    # move a slottable (an insertion or removal under a host or in a shadow
    # tree, a `slot` or `name` attribute change, `assign()`), and signals the
    # slots whose assigned nodes came out different. Dommy derives assigned
    # nodes on read, so it does the same by comparing each slot's current
    # assigned nodes with those it had when last looked at here.
    #
    # Spec: https://dom.spec.whatwg.org/#signal-a-slot-change
    class SlotSignals
      def initialize(document)
        @document = document
      end

      # Re-assign the slots of `shadow_root`'s tree, signaling the ones that
      # changed.
      def assign_slottables_for_tree(shadow_root)
        return unless shadow_root

        shadow_root.query_selector_all("slot").each { |slot| reassign(slot) }
      end

      # Slots in a subtree that just left a shadow tree (backend node `root`)
      # lose whatever was assigned to them.
      def removed_subtree(root)
        NodeTraversal.subtree_nodes(root).each do |node|
          next unless node.element? && node.name.casecmp?("slot")

          slot = @document.__internal_peek_wrapper__(node)
          reassign(slot) if slot.is_a?(HTMLSlotElement)
        end
      end

      # A slot showing its fallback content (no assigned nodes) has changed
      # when its children did.
      def fallback_changed(slot)
        signal(slot) if slot.assigned_nodes.empty? && @document.__internal_shadow_root_containing__(slot.__dommy_backend_node__)
      end

      # A document with no window has no event loop to fire it from.
      def signal(slot)
        @document.default_view&.__internal_mutation_observer_microtask__&.signal_slot(slot)
      end

      private

      def reassign(slot)
        current = slot.assigned_nodes
        previous = slot.__internal_last_assigned_nodes__ || []
        slot.__internal_last_assigned_nodes__ = current
        signal(slot) unless same_nodes?(current, previous)
      end

      def same_nodes?(a, b)
        a.length == b.length && a.zip(b).all? { |x, y| x.equal?(y) }
      end
    end
  end
end
