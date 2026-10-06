# frozen_string_literal: true

require_relative "idl_reflection_table"

module Dommy
  module Internal
    # The ARIA surface: the `role` attribute, the computed role/name/
    # description, and the element-reflecting aria-* properties.
    #
    # Host contract: @__node__, @document responding to #wrap_node,
    # #__internal_attribute_value__ / #__internal_set_attribute_value__ /
    # #remove_attribute_ns, #root_node and #accessibility_tree. Every content
    # attribute here is the one in no namespace, as ARIA reflects it.
    module ElementAria
      # ARIAMixin's IDL attributes (WAI-ARIA §10.1), each with the content
      # attribute it reflects, read from the specs' own IDL (the generated
      # IdlReflection::TABLE, where ARIAMixin is folded into Element): the
      # `DOMString?` ones, the one singular element reference (`Element?`) and
      # the element-list references (`FrozenArray<Element>?`). A name outside
      # these is no reflection — `ariaFoo` and `ariaLabelledBy` are plain
      # expandos, as in a browser. `role` is reflected too.
      ARIA_REFLECTIONS = IdlReflection::TABLE.fetch("Element").select { |name, _| name.start_with?("aria") }
      private_constant :ARIA_REFLECTIONS

      def self.aria_attributes(idl_type)
        ARIA_REFLECTIONS.select { |_, entry| entry[:idl] == idl_type }
                        .to_h { |name, entry| [name, entry.fetch(:attr)] }
      end
      private_class_method :aria_attributes

      STRING_ATTRIBUTES = aria_attributes("DOMString?").merge("role" => "role").freeze
      ELEMENT_ATTRIBUTES = aria_attributes("Element?").freeze
      ELEMENTS_ATTRIBUTES = aria_attributes("FrozenArray<Element>?").freeze

      # Every JS property this module answers on an Element's bridge (through
      # Element#__js_get__'s table lookups rather than a `when` arm), for the
      # WebIDL audit and the generated prototype members to see.
      JS_PROPERTY_NAMES = (STRING_ATTRIBUTES.keys + ELEMENT_ATTRIBUTES.keys + ELEMENTS_ATTRIBUTES.keys).freeze

      def role
        __internal_attribute_value__("role").to_s
      end

      def role=(value)
        __internal_set_attribute_value__("role", value.to_s)
      end

      # The WAI-ARIA computed role (what `getByRole` / WPT's get_computed_role
      # report): an explicit valid `role` attribute, else the implicit HTML role.
      def computed_role
        Internal::AriaRole.compute(self)
      end

      # The WAI-ARIA accessible name (WPT's get_computed_label): aria-labelledby /
      # aria-label / native label / name-from-content / title.
      def computed_label
        Internal::AccessibleName.compute(self)
      end

      # The WAI-ARIA accessible description: aria-describedby / aria-description /
      # title (title only when not already used as the accessible name).
      def computed_description
        Internal::AccessibleDescription.compute(self)
      end

      # A Playwright-compatible ARIA snapshot (indented YAML outline) of this
      # element's accessibility subtree.
      def aria_snapshot
        Internal::AriaSnapshot.serialize(accessibility_tree)
      end

      # Read an ARIA element reference: an explicitly-set Element wins; otherwise
      # the content attribute is resolved as an IDREF (the element with that id in
      # this element's tree), or null.
      def aria_element_get(content_attr, key)
        explicit = (@aria_element_refs ||= {})[key]
        if explicit
          # An explicitly-set attr-element is only observable while it stays in a
          # valid scope: a shadow-including descendant of one of this element's
          # shadow-including ancestors. A reference that crosses into a shadow tree
          # (or whose target is reparented out of scope) reads as null.
          return aria_ref_in_valid_scope?(explicit) ? explicit : nil
        end

        idref = __internal_attribute_value__(content_attr).to_s
        return nil if idref.empty?

        aria_find_in_root(idref)
      end

      # Set an ARIA element reference: null/undefined clears it and removes the
      # content attribute; an Element stores the explicit reference and sets the
      # content attribute to the empty string (per the reflection spec).
      def aria_element_set(content_attr, key, value)
        refs = (@aria_element_refs ||= {})
        if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
          refs.delete(key)
          remove_attribute_ns(nil, content_attr)
        else
          # WebIDL: the value is an `Element?` — a non-Element throws a TypeError.
          raise Bridge::TypeError, "value is not an Element or null" unless value.is_a?(Dommy::Element)

          # The write clears explicit refs via its aria-* hook, so store the
          # new reference afterward.
          __internal_set_attribute_value__(content_attr, "")
          refs[key] = value
        end
        nil
      end

      # Read a plural ARIA element references value (a list of Elements): the
      # explicitly-set array wins; otherwise the content attribute is split as a
      # space-separated IDREF list and each resolved (missing ids dropped).
      #
      # The IDL type is FrozenArray<Element>?: the elements cross to script as
      # a plain Array, and the JS side hands back the frozen array it gave out
      # last for as long as they are the same ones (host_runtime.js
      # frozenArrayRead), so this answers only with what they are now.
      def aria_elements_get(content_attr, key)
        aria_elements_current(content_attr, key)
      end

      # Set a plural ARIA element references value: null/undefined clears it and
      # removes the content attribute; an array of Elements is stored and the
      # content attribute is set to the empty string.
      def aria_elements_set(content_attr, key, value)
        refs = (@aria_elements_refs ||= {})
        if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
          refs.delete(key)
          remove_attribute_ns(nil, content_attr)
        else
          # WebIDL: the value is a `sequence<Element>?` — a non-array, or an array
          # containing a non-Element, throws a TypeError.
          unless value.is_a?(Array) && value.all? { |el| el.is_a?(Dommy::Element) }
            raise Bridge::TypeError, "value is not a sequence of Elements"
          end

          __internal_set_attribute_value__(content_attr, "")
          refs[key] = value.dup
        end
        nil
      end

      # The current resolved element list for a plural ARIA element reference, or
      # nil when neither explicit elements nor the content attribute are present. An
      # explicitly-set list wins (out-of-scope entries dropped); otherwise the
      # content attribute is split as space-separated IDREFs and each resolved.
      def aria_elements_current(content_attr, key)
        explicit = (@aria_elements_refs ||= {})[key]
        return explicit.select { |el| aria_ref_in_valid_scope?(el) } if explicit

        idrefs = __internal_attribute_value__(content_attr)
        return nil if idrefs.nil?

        idrefs.split(/[ \t\n\f\r]+/).reject(&:empty?).filter_map do |id|
          aria_find_in_root(id)
        end
      end

      # The elements an ARIA element-list attribute (`aria-labelledby`)
      # associates with this one, as its reflection resolves them — the
      # explicitly-set elements, else the IDREFs found in this element's tree —
      # for the name, description and role to follow the same references.
      # nil with neither.
      def __internal_aria_associated_elements__(content_attr)
        aria_elements_current(content_attr, ELEMENTS_ATTRIBUTES.key(content_attr))
      end

      # Resolve an ARIA IDREF within this element's tree ROOT (its topmost
      # ancestor) rather than the document — so references keep working when the
      # subtree is disconnected from the document or in a shadow tree. In the
      # document, its own id lookup answers, natively; anywhere else the tree
      # is searched, as it is small and has no index.
      def aria_find_in_root(id)
        root = NodeTraversal.root_of(@__node__)
        return @document.get_element_by_id(id) if root.equal?(@document.backend_doc)

        node = root.element? && Backend.no_namespace_attribute_value(root, "id") == id ? root : nil
        node ||= root.css("*").find { |n| Backend.no_namespace_attribute_value(n, "id") == id }
        node && @document.wrap_node(node)
      end

      # WHATWG "reflecting element references" scope check: `attr_element` is valid
      # iff its root is this element's root or a shadow-including-ancestor root
      # (reached by hopping each shadow root to its host). So a same-tree reference
      # and a reference to a shadow-inclusive ancestor are valid, but crossing into
      # a shadow tree (or a sibling/detached scope) is not.
      def aria_ref_in_valid_scope?(attr_element)
        return false unless attr_element.respond_to?(:root_node)

        target_root = attr_element.root_node
        scope = self
        loop do
          root = scope.root_node
          return true if root.equal?(target_root)

          host = root.respond_to?(:host) ? root.host : nil
          return false unless host

          scope = host
        end
      end
    end
  end
end
