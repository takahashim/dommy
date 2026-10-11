# frozen_string_literal: true

module Dommy
  module Internal
    # DOM "signal a slot change": a slot whose assigned nodes changed joins the
    # signal slots of the window that serves the document, and the mutation
    # observer microtask fires `slotchange` at each of them, once, after the
    # MutationObservers' records (Internal::MutationObserverMicrotask).
    #
    # The spec re-runs "assign slottables for a tree" at each mutation that can
    # move a slottable and signals the slots whose assigned nodes came out
    # different. Dommy reads assigned nodes from the tree when asked
    # (SlotAssignment), so it works out from the mutation itself which slots
    # changed, as browsers do, rather than recomputing and comparing every
    # slot's assigned nodes:
    #
    #   - a slottable added to or removed from a host changes the slot it goes
    #     to (named: the first slot of its name; manual: the slot it is
    #     assigned to);
    #   - a slottable's `slot` attribute moves it from the first slot of the old
    #     name to the first slot of the new one;
    #   - a slot coming into or leaving a shadow tree, or renamed, changes which
    #     slot is first for a name, and the old and new first slots of a name
    #     the host has slottables for both change. Each ShadowRoot keeps its
    #     first slot of each name (`__internal_first_slots__`) to compare with.
    #
    # Spec: https://dom.spec.whatwg.org/#signal-a-slot-change
    class SlotSignals
      def initialize(document)
        @document = document
      end

      # The host of `shadow` had `added` and `removed` children (backend nodes).
      def host_children_changed(shadow, added, removed)
        if shadow.slot_assignment == "manual"
          (added + removed).each do |node|
            slot = @document.__internal_peek_wrapper__(node)&.__internal_manual_slot__
            signal(slot) if slot && in_tree?(slot, shadow)
          end
        else
          firsts = first_slots(shadow)
          names = (added + removed).filter_map { |node| SlotAssignment.slottable_name(node) if SlotAssignment.slottable?(node) }
          names.uniq.each { |name| signal_node(firsts[name]) }
        end
      end

      # A child of the host of `shadow` changed its `slot` attribute.
      def slottable_renamed(shadow, old_name, new_name)
        return if shadow.slot_assignment == "manual" || old_name == new_name

        firsts = first_slots(shadow)
        signal_node(firsts[old_name])
        signal_node(firsts[new_name])
      end

      # The slots of `shadow`'s tree changed: `added` slots came in, `removed`
      # ones left (backend nodes), or a slot's name changed.
      def slots_changed(shadow, added: [], removed: [])
        return manual_slots_changed(shadow, added + removed) if shadow.slot_assignment == "manual"

        before = shadow.__internal_first_slots__ || first_slots_without(shadow, added)
        after = SlotAssignment.first_slots_by_name(shadow)
        shadow.__internal_first_slots__ = after
        host_node = shadow.host&.__dommy_backend_node__
        return unless host_node

        changed = []
        (before.keys | after.keys).each do |name|
          next if SlotAssignment.same_node?(before[name], after[name])
          next unless SlotAssignment.slottable_named?(host_node, name)

          changed.push(*[before[name], after[name]].compact)
        end
        return if changed.empty?

        # "Assign slottables for a tree" signals the tree's slots in tree order;
        # the removing steps then run it for the removed subtree.
        keys = changed.to_h { |node| [Backend.identity_key(node), true] }
        SlotAssignment.slot_nodes(shadow.__dommy_backend_node__).each { |node| signal_node(node) if keys.delete(Backend.identity_key(node)) }
        removed.each { |node| signal_node(node) if keys.delete(Backend.identity_key(node)) }
      end

      # A slot showing its fallback content (no assigned nodes) has changed
      # when its children did.
      def fallback_changed(slot)
        return unless @document.__internal_shadow_root_containing__(slot.__dommy_backend_node__)

        signal(slot) if SlotAssignment.find_slottables(@document, slot).empty?
      end

      # The window whose event loop serves the document: its own, or for a
      # document with none (createHTMLDocument, DOMParser) the one of the
      # document that made it — the agent's mutation observer microtask.
      def signal(slot)
        @document.__internal_event_loop_window__&.__internal_mutation_observer_microtask__&.signal_slot(slot)
      end

      private

      def signal_node(node)
        return unless node

        slot = @document.wrap_node(node)
        signal(slot) if slot.is_a?(HTMLSlotElement)
      end

      # In a manual-assignment tree a slot coming or going changes only when
      # it holds some of the host's children.
      def manual_slots_changed(shadow, slot_nodes)
        host_node = shadow.host&.__dommy_backend_node__
        return unless host_node

        slot_nodes.each do |node|
          slot = @document.__internal_peek_wrapper__(node)
          signal(slot) if slot.is_a?(HTMLSlotElement) && !SlotAssignment.manual_slottables(slot, host_node).empty?
        end
      end

      def first_slots(shadow)
        shadow.__internal_first_slots__ ||= SlotAssignment.first_slots_by_name(shadow)
      end

      # The first slots before `added` came in.
      def first_slots_without(shadow, added)
        keys = added.to_h { |node| [Backend.identity_key(node), true] }
        firsts = {}
        SlotAssignment.slot_nodes(shadow.__dommy_backend_node__).each do |node|
          firsts[SlotAssignment.slot_name(node)] ||= node unless keys.key?(Backend.identity_key(node))
        end
        firsts
      end

      def in_tree?(slot, shadow)
        @document.__internal_shadow_root_containing__(slot.__dommy_backend_node__).equal?(shadow)
      end
    end
  end
end
