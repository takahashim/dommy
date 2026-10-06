# frozen_string_literal: true

module Dommy
  module Internal
    # Attaching a shadow tree, and the slot a light child is assigned to.
    #
    # Host contract: @__node__, @document responding to #wrap_node and
    # #__internal_shadow_root_for_host__, and #set_attribute.
    module ElementShadow
      # The local names that may host a shadow tree besides a valid custom
      # element name — together, DOM's "valid shadow host name".
      SHADOW_HOST_TAGS = %w[
        article
        aside
        blockquote
        body
        div
        footer
        h1
        h2
        h3
        h4
        h5
        h6
        header
        main
        nav
        p
        section
        span
      ]
        .freeze

      # `slot` and `role` are simple reflected string attributes —
      # added as named accessors for happy-dom test parity.
      def slot
        __internal_attribute_value__("slot").to_s
      end

      def slot=(value)
        __internal_set_attribute_value__("slot", value.to_s)
      end

      # `assignedSlot` — for a slottable (a direct light-DOM child of a shadow
      # host), the `<slot>` in the host's *open* shadow tree it composes into,
      # else null. Per the spec's "open flag", a closed shadow tree always
      # returns null (mirrors `Element#shadowRoot` being null when closed).
      def assigned_slot
        parent = @__node__.parent
        return nil unless parent&.element?

        host = @document.wrap_node(parent)
        return nil unless host.respond_to?(:shadow_root)

        sr = host.shadow_root
        return nil unless sr

        slot_name = @__node__.element? ? __internal_attribute_value__("slot").to_s : ""
        sr.query_selector_all("slot").find do |slot|
          (slot.respond_to?(:name) ? slot.name.to_s : "") == slot_name
        end
      end

      # `el.attachShadow(init)` (DOM): the ShadowRootInit dictionary is
      # converted first — `mode` is required and, like `slotAssignment`, an
      # enum, so a missing or unknown value is a TypeError before any of the
      # algorithm's DOMExceptions — then the registry check, then "attach a
      # shadow root". Returns the element's shadow root: a new one, or the
      # declarative one the parser gave it, emptied.
      def attach_shadow(options = nil)
        init = shadow_root_init(options)
        registry = shadow_root_registry(init)
        # The document's own registry is what an unset one stands for.
        registry = :document if registry.equal?(CustomElementRegistry.effective_global_for(owner_document))
        __internal_attach_shadow_root__(
          mode: init[:mode], delegates_focus: init[:delegates_focus], serializable: init[:serializable],
          slot_assignment: init[:slot_assignment], clonable: init[:clonable], registry: registry
        )
        __internal_shadow_root__
      end

      # DOM "attach a shadow root". `registry` is the shadow root's custom
      # element registry (nil: null; :document for the document's own, the
      # default). Raises NotSupportedError where the algorithm throws, and
      # returns the new ShadowRoot — or nil when it emptied an existing
      # declarative one instead.
      def __internal_attach_shadow_root__(mode:, delegates_focus: false, serializable: false,
        slot_assignment: "named", clonable: false, registry: :document)
        name = local_name
        # Steps 1-2: an HTML element with a valid shadow host name — a name in
        # SHADOW_HOST_TAGS or a valid custom element name, case-sensitively.
        unless namespace_uri == Namespaces::HTML &&
            (SHADOW_HOST_TAGS.include?(name) || CustomElementRegistry.valid_name?(name))
          raise DOMException::NotSupportedError, "<#{name}> cannot host a shadow root"
        end

        # Step 3: a defined custom element's definition may disable shadow.
        if CustomElementRegistry.valid_name?(name) || !__internal_is_value__.nil?
          definition = CustomElementRegistry.lookup(__internal_ce_registry__, namespace_uri, name, __internal_is_value__)
          raise DOMException::NotSupportedError, "the custom element definition disables shadow" if definition&.disable_shadow?
        end

        # Step 4: a host may only "re-attach" over the declarative shadow root
        # the parser gave it, of the same mode — which is emptied, in tree
        # order, and stops being declarative.
        if (current = __internal_shadow_root__)
          unless current.__internal_declarative__? && current.mode == mode
            raise DOMException::NotSupportedError, "Shadow root already attached"
          end

          current.child_nodes.to_a.each { |child| current.remove_child(child) }
          current.__internal_declarative__ = false
          return nil
        end

        # Step 9: a custom element being constructed or constructed: the
        # shadow root is available to its ElementInternals.
        constructed = %w[precustomized custom].include?(__internal_custom_element_state__)
        shadow = ShadowRoot.new(self, mode: mode, delegates_focus: delegates_focus, slot_assignment: slot_assignment,
                                      clonable: clonable, serializable: serializable)
        shadow.__internal_available_to_internals__ = true if constructed
        shadow.__internal_custom_element_registry__ = registry unless registry == :document
        @__shadow_root = shadow
      end

      # `el.shadowRoot` — returns the attached ShadowRoot only when
      # mode is "open"; closed shadows are hidden from external code.
      def shadow_root
        root = __internal_shadow_root__
        return nil if root.nil? || root.mode == "closed"

        root
      end

      # Internal — gives access to the shadow root regardless of mode.
      # Used by event composition / `composedPath()`. The document's registry
      # answers for a wrapper that is not the one attachShadow ran on: a custom
      # element upgrade replaces the host's wrapper, not its shadow root.
      def __internal_shadow_root__
        @__shadow_root ||= @document.__internal_shadow_root_for_host__(@__node__)
      end

      private

      # The ShadowRootInit dictionary, converted as WebIDL does it: members in
      # lexicographic order, `mode` required.
      def shadow_root_init(options)
        opts = options.is_a?(Hash) ? options : {}
        member = lambda do |key|
          value = opts.key?(key) ? opts[key] : opts[key.to_sym]
          value.equal?(Bridge::UNDEFINED) ? nil : value
        end
        init = {
          clonable: WebIDL.boolean(member.call("clonable")),
          delegates_focus: WebIDL.boolean(member.call("delegatesFocus"))
        }
        registry_given = opts.key?("customElementRegistry") && !opts["customElementRegistry"].equal?(Bridge::UNDEFINED)
        if registry_given
          given = opts["customElementRegistry"]
          raise Bridge::TypeError, "customElementRegistry is not a CustomElementRegistry" unless given.nil? || given.is_a?(CustomElementRegistry)

          init[:registry] = given
        end
        mode_raw = member.call("mode")
        raise Bridge::TypeError, "attachShadow init dictionary requires 'mode'" if mode_raw.nil?

        init[:mode] = mode_raw.to_s
        raise Bridge::TypeError, "mode must be 'open' or 'closed'" unless %w[open closed].include?(init[:mode])

        init[:serializable] = WebIDL.boolean(member.call("serializable"))
        slot = member.call("slotAssignment")
        init[:slot_assignment] = slot.nil? ? "named" : slot.to_s
        raise Bridge::TypeError, "slotAssignment must be 'named' or 'manual'" unless %w[named manual].include?(init[:slot_assignment])

        init
      end

      # attachShadow() steps 1-3: the init's `customElementRegistry`, else the
      # document's; a global one other than the document's is a
      # NotSupportedError.
      def shadow_root_registry(init)
        registry = init.key?(:registry) ? init[:registry] : CustomElementRegistry.for_document(owner_document)
        if registry && !registry.scoped? && !registry.equal?(CustomElementRegistry.for_document(owner_document))
          raise DOMException::NotSupportedError, "a global registry other than the document's"
        end

        registry
      end
    end
  end
end
