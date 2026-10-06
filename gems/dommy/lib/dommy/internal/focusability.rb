# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's focus model (§6.6 "Focus"), minus the parts that need layout or a
    # keyboard: which elements are focusable areas, the focusing and
    # unfocusing steps, the focus delegate a shadow host or dialog hands focus
    # to, and inertness, which takes an element out of all of it.
    #
    # A document's focused area is its focused element, or the viewport when
    # it has none; Document keeps it (DocumentInteractionState) and runs the
    # focus update steps, which fire the events.
    #
    # Focusable areas are elements only: an image map's shapes and scrollable
    # regions need layout, and focusing an iframe leaves focus on the iframe
    # rather than entering its document.
    module Focusability
      module_function

      # The elements a user agent considers focusable without a tabindex
      # (HTML §6.6.3's suggested list, plus dialog, which Chromium and the
      # dialog focusing steps treat as focusable but not sequentially so).
      ALWAYS_FOCUSABLE = %w[button select textarea iframe frame dialog].freeze

      # HTML "focusable area": the tabindex value is non-null or the user
      # agent considers the element focusable; it is no shadow host whose
      # shadow root delegates focus; it is not actually disabled, not inert,
      # and being rendered.
      def focusable_area?(element)
        return false unless element.is_a?(Element) && element.is_connected?
        return false unless !tabindex_value(element).nil? || ua_focusable?(element)
        return false if delegates_focus?(element)
        return false if actually_disabled?(element)
        return false if inert?(element)

        being_rendered?(element)
      end

      # Sequentially focusable: a focusable area whose tabindex is not
      # negative — or, with none, one the user agent puts in the sequential
      # navigation order (everything it considers focusable but a dialog).
      def sequentially_focusable?(element)
        return false unless focusable_area?(element)

        value = tabindex_value(element)
        value.nil? ? !(html?(element) && element.local_name == "dialog") : value >= 0
      end

      # Click focusable: every focusable area. (A user agent may decline
      # some; Dommy does not.)
      def click_focusable?(element) = focusable_area?(element)

      # The tabindex value: the attribute parsed with the rules for parsing
      # integers, nil when it is missing or does not parse.
      def tabindex_value(element)
        raw = element.__internal_attribute_value__("tabindex")
        return nil if raw.nil?

        match = /\A[\t\n\f\r ]*([+-]?\d+)/.match(raw)
        return nil unless match

        value = match[1].to_i
        value.between?(-2**31, 2**31 - 1) ? value : nil
      end

      def ua_focusable?(element)
        if html?(element)
          name = element.local_name
          return true if ALWAYS_FOCUSABLE.include?(name)
          return !element.__internal_attribute_value__("type").to_s.casecmp?("hidden") if name == "input"
          return element.__internal_has_attribute__?("href") if name == "a"
          return true if name == "summary" && element.respond_to?(:__internal_summary_details__) &&
            element.__internal_summary_details__

          editing_host?(element)
        elsif element.namespace_uri == Namespaces::SVG
          element.local_name == "a" &&
            (element.__internal_has_attribute__?("href") || element.has_attribute_ns?(Namespaces::XLINK, "href"))
        else
          false
        end
      end

      # HTML "editing host": an HTML element whose contenteditable is true or
      # plaintext-only, or the document element of a document in design mode.
      def editing_host?(element)
        return true if %i[true plaintext_only].include?(ElementEditing.state(element))

        document = element.owner_document
        document.document_element.equal?(element) && document.__internal_design_mode__?
      end

      def delegates_focus?(element)
        root = element.respond_to?(:__internal_shadow_root__) ? element.__internal_shadow_root__ : nil
        root ? root.delegates_focus : false
      end

      def actually_disabled?(element) = element.__internal_actually_disabled__

      # "Being rendered" (having a layout box), approximated without layout:
      # connected, in the flat tree, in a rendered frame, not display:
      # contents itself (which generates no box — a slot, by default), and
      # with no flat-tree inclusive ancestor whose computed display is none.
      def being_rendered?(element)
        style_for = ->(el) { CSS::Cascade.computed_style(el) }
        return false if CSS::Renderability.not_rendered?(element, style_for)
        return false if style_for.call(element)["display"] == "contents"

        node = element
        while node.is_a?(Element)
          return false if style_for.call(node)["display"] == "none"

          node = flat_tree_parent(node)
        end
        true
      end

      # HTML "inert". While a modal dialog blocks the document, every node
      # outside it is inert; the dialog and what it contains become inert only
      # through an inert attribute between them and the dialog. Otherwise a
      # node is inert when an HTML element among its flat-tree inclusive
      # ancestors has the inert attribute.
      def inert?(node)
        element = node.is_a?(Element) ? node : node.parent_element
        return false if element.nil?

        document = element.owner_document
        blocker = document.respond_to?(:__internal_blocking_modal_dialog__) ? document.__internal_blocking_modal_dialog__ : nil
        blocker = nil unless blocker && element.is_connected?
        current = element
        while current.is_a?(Element)
          return true if html?(current) && current.__internal_has_attribute__?("inert")
          return false if blocker && current.equal?(blocker)

          current = flat_tree_parent(current)
        end
        !blocker.nil?
      end

      # HTML "get the focusable area" for a target that is no focusable area:
      # the viewport for the document element (:viewport), the focus
      # delegate for a shadow host that delegates focus (or what it already
      # holds focused), else nil.
      def focusable_area_for(target, trigger = "other")
        return :viewport if target.owner_document.document_element.equal?(target)
        return nil unless delegates_focus?(target)

        focused = target.owner_document.__internal_focused_element__
        return focused if focused && shadow_including_inclusive_ancestor?(target, focused)

        focus_delegate(target, trigger)
      end

      # HTML "focus delegate": the autofocus delegate of the target (its
      # shadow root, for a host), else its first descendant that is a
      # focusable area — sequentially focusable, for a dialog — or that hands
      # focus on to one.
      def focus_delegate(target, trigger = "other")
        return nil if target.respond_to?(:__internal_shadow_root__) && target.__internal_shadow_root__ &&
          !delegates_focus?(target)

        where = (target.respond_to?(:__internal_shadow_root__) && target.__internal_shadow_root__) || target
        delegate = autofocus_delegate(where, trigger)
        return delegate if delegate

        dialog = target.is_a?(Element) && html?(target) && target.local_name == "dialog"
        each_descendant_element(where) do |descendant|
          area =
            if dialog
              sequentially_focusable?(descendant) ? descendant : nil
            elsif focusable_area?(descendant)
              descendant
            end
          area ||= focusable_area_or_nil(descendant, trigger)
          return area if area
        end
        nil
      end

      # HTML "autofocus delegate": the first descendant with an autofocus
      # attribute that is, or hands focus on to, a focusable area (click
      # focusable, for a click).
      def autofocus_delegate(target, trigger = "other")
        each_descendant_element(target) do |descendant|
          next unless descendant.__internal_has_attribute__?("autofocus")

          area = focusable_area?(descendant) ? descendant : focusable_area_or_nil(descendant, trigger)
          next if area.nil?
          next if trigger == "click" && !click_focusable?(area)

          return area
        end
        nil
      end

      # HTML "focusing steps" for an element. `fallback` is used when neither
      # it nor a delegate is focusable. Answers whether focus moved.
      def run_focusing_steps(target, fallback: nil, trigger: "other")
        document = target.owner_document
        area = focusable_area?(target) ? target : focusable_area_for(target, trigger)
        area = fallback if area.nil?
        return false if area.nil?

        if area == :viewport
          document.__internal_focus_update__(nil)
          return true
        end
        return false if inert?(area)
        return false if document.__internal_focused_element__.equal?(area)

        document.__internal_focus_update__(area)
        true
      end

      # HTML "unfocusing steps": a focused element (or a shadow host holding
      # the focus inside its delegating shadow tree) gives focus back to the
      # viewport.
      def run_unfocusing_steps(target)
        document = target.owner_document
        focused = document.__internal_focused_element__
        return if focused.nil?

        target = focused if delegates_focus?(target) &&
          shadow_including_inclusive_ancestor?(target.__internal_shadow_root__, focused)
        return if inert?(target)
        return unless focused.equal?(target)

        document.__internal_focus_update__(nil)
      end

      # A node's parent in the flat tree: a shadow root's host stands in for
      # the root, and a shadow host's child hangs from the slot it is
      # assigned to (or from nothing, unslotted).
      def flat_tree_parent(node)
        parent = node.parent_node
        return parent.host if parent.is_a?(ShadowRoot)
        return nil unless parent.is_a?(Element)
        return parent unless parent.respond_to?(:__internal_shadow_root__) && parent.__internal_shadow_root__

        node.respond_to?(:assigned_slot) ? node.assigned_slot : nil
      end

      def shadow_including_inclusive_ancestor?(ancestor, node)
        Retargeting.shadow_including_inclusive_ancestor?(ancestor, node)
      end

      def html?(element) = element.namespace_uri == Namespaces::HTML

      def focusable_area_or_nil(element, trigger)
        area = focusable_area_for(element, trigger)
        area == :viewport ? nil : area
      end

      # The descendant elements of an element or shadow root, in tree order
      # (not shadow-including: a shadow host is reached through its own
      # focus delegate).
      def each_descendant_element(root, &block)
        root.children.to_a.each do |child|
          yield child
          each_descendant_element(child, &block)
        end
      end

      private_class_method :ua_focusable?, :html?, :focusable_area_or_nil, :each_descendant_element
    end
  end
end
