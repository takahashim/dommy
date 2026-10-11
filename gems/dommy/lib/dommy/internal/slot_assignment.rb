# frozen_string_literal: true

module Dommy
  module Internal
    # DOM slot assignment, read from the tree when asked: "find a slot" gives
    # the slot a slottable goes to, "find slottables" the slottables a slot
    # gets. Only an HTML `<slot>` is a slot (an SVG or MathML one is an
    # ordinary element), and only an Element or a Text node is a slottable.
    #
    # Spec: https://dom.spec.whatwg.org/#find-a-slot
    module SlotAssignment
      module_function

      # Whether backend node `node` is an HTML slot element.
      def slot_node?(node)
        node.element? && node.local_name == "slot" && Backend.namespace_uri(node) == Namespaces::HTML
      end

      # DOM "slottable": an Element or a Text node.
      def slottable?(node)
        node.element? || node.text?
      end

      # The HTML slots of the subtree rooted at backend node `root` (an
      # element or a fragment, itself included), in tree order, found by the
      # backend's selector engine rather than a walk in Ruby.
      def slot_nodes(root)
        return [] unless root.element? || root.is_a?(Backend.document_fragment_class)

        slots = root.css("slot").select { |node| slot_node?(node) }
        slots.unshift(root) if slot_node?(root)
        slots
      end

      # A slottable's name: an element's `slot` attribute, a Text node's "".
      def slottable_name(node)
        node.element? ? Backend.no_namespace_attribute_value(node, "slot").to_s : ""
      end

      # A slot's name: its `name` attribute.
      def slot_name(node)
        Backend.no_namespace_attribute_value(node, "name").to_s
      end

      # The first slot of each name in `shadow`'s tree, as name => backend node.
      def first_slots_by_name(shadow)
        firsts = {}
        slot_nodes(shadow.__dommy_backend_node__).each { |node| firsts[slot_name(node)] ||= node }
        firsts
      end

      # DOM "find a slot" for backend node `node`: the wrapped slot, or nil.
      # `open` is the spec's open flag: a closed shadow tree's slot is nil.
      def find_slot(document, node, open: false)
        parent = node.parent
        return nil unless parent&.element? && slottable?(node)

        shadow = document.__internal_shadow_root_for_host__(parent)
        return nil unless shadow
        return nil if open && shadow.mode != "open"

        if shadow.slot_assignment == "manual"
          slot = document.__internal_peek_wrapper__(node)&.__internal_manual_slot__
          return slot if slot && document.__internal_shadow_root_containing__(slot.__dommy_backend_node__).equal?(shadow)

          return nil
        end

        name = slottable_name(node)
        found = slot_nodes(shadow.__dommy_backend_node__).find { |slot| slot_name(slot) == name }
        found && document.wrap_node(found)
      end

      # DOM "find slottables" for a wrapped slot: its slottables, wrapped, in
      # tree order (named) or assignment order (manual).
      def find_slottables(document, slot)
        slot_node = slot.__dommy_backend_node__
        shadow = document.__internal_shadow_root_containing__(slot_node)
        host_node = shadow&.host&.__dommy_backend_node__
        return [] unless host_node
        return manual_slottables(slot, host_node) if shadow.slot_assignment == "manual"

        name = slot_name(slot_node)
        first = slot_nodes(shadow.__dommy_backend_node__).find { |node| slot_name(node) == name }
        return [] unless first && same_node?(first, slot_node)

        host_node.children.filter_map do |child|
          document.wrap_node(child) if slottable?(child) && slottable_name(child) == name
        end
      end

      # A manual slot's assigned nodes that are `host_node`'s children.
      def manual_slottables(slot, host_node)
        host_key = Backend.identity_key(host_node)
        slot.__internal_manual_assignment__.select do |node|
          parent = node.__dommy_backend_node__&.parent
          parent && Backend.identity_key(parent) == host_key
        end
      end

      # Whether `host_node` has a slottable child named `name`.
      def slottable_named?(host_node, name)
        host_node.children.any? { |child| slottable?(child) && slottable_name(child) == name }
      end

      def same_node?(a, b)
        a.nil? ? b.nil? : (!b.nil? && Backend.identity_key(a) == Backend.identity_key(b))
      end
    end
  end
end
