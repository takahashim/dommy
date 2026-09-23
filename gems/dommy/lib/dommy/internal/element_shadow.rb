# frozen_string_literal: true

module Dommy
  module Internal
    # Attaching a shadow tree, and the slot a light child is assigned to.
    #
    # Element's, but not about being an element: it was 2200 lines holding
    # these four subjects alongside attributes, selectors and serialization.
    module ElementShadow
      # Elements that may host a Shadow DOM tree per the HTML spec.
      # Custom-element-style names (containing "-") are also allowed.
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
        @__node__["slot"].to_s
      end

      def slot=(value)
        set_attribute("slot", value.to_s)
      end

      # `assignedSlot` — for a slottable (a direct light-DOM child of a shadow
      # host), the `<slot>` in the host's *open* shadow tree it composes into,
      # else null. Per the spec's "open flag", a closed shadow tree always
      # returns null (mirrors `Element#shadowRoot` being null when closed).
      def assigned_slot
        parent = @__node__.parent
        return nil unless parent.respond_to?(:element?) && parent.element?
  
        host = @document.wrap_node(parent)
        return nil unless host.respond_to?(:shadow_root)
  
        sr = host.shadow_root
        return nil unless sr
  
        slot_name = @__node__.element? ? @__node__["slot"].to_s : ""
        sr.query_selector_all("slot").find do |slot|
          (slot.respond_to?(:name) ? slot.name.to_s : "") == slot_name
        end
      end

      # `el.attachShadow({ mode: "open" | "closed" })` — creates and
      # attaches a ShadowRoot. The shadow tree lives in its own
      # Nokogiri fragment and is invisible to the outer querySelector /
      # children chain. Per spec:
      #   - the `mode` field is REQUIRED in the init dict
      #   - only certain host element types are valid (see SHADOW_HOST_TAGS)
      #   - re-attaching to an element that already has a shadow throws
      def attach_shadow(options = nil)
        tag = @__node__.name.downcase
        unless SHADOW_HOST_TAGS.include?(tag) || tag.include?("-")
          raise DOMException::NotSupportedError, "<#{tag}> cannot host a shadow root"
        end
  
        raise DOMException::NotSupportedError, "Shadow root already attached" if __internal_shadow_root__
  
        opts = options.is_a?(Hash) ? options : {}
        mode_raw = opts.key?("mode") ? opts["mode"] : opts[:mode]
        # `mode` is a required WebIDL dictionary member — omitting it, like an
        # invalid enum value below, is a (JS) TypeError, not a DOMException.
        raise Bridge::TypeError, "attachShadow init dictionary requires 'mode'" if mode_raw.nil?
  
        # `mode` is a WebIDL enum (ShadowRootMode); a value that isn't "open"/
        # "closed" fails enum conversion → TypeError, not a DOMException.
        mode = mode_raw.to_s
        raise Bridge::TypeError, "mode must be 'open' or 'closed'" unless %w[open closed].include?(mode)
  
        @__shadow_root = ShadowRoot.new(
          self,
          mode: mode,
          delegates_focus: opts["delegatesFocus"] || opts[:delegatesFocus] || false,
          slot_assignment: opts["slotAssignment"] || opts[:slotAssignment] || "named"
        )
        @__shadow_root
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
    end
  end
end
