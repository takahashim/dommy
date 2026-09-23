# frozen_string_literal: true

module Dommy
  module Internal
    # The ARIA surface: the `role` attribute, the computed role/name/
    # description, and the element-reflecting aria-* properties.
    #
    # Element's, but not about being an element: it was 2200 lines holding
    # these four subjects alongside attributes, selectors and serialization.
    module ElementAria
      def role
        @__node__["role"].to_s
      end

      def role=(value)
        set_attribute("role", value.to_s)
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
  
        idref = @__node__[content_attr].to_s
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
          remove_attribute(content_attr) if @__node__.key?(content_attr)
        else
          # WebIDL: the value is an `Element?` — a non-Element throws a TypeError.
          raise Bridge::TypeError, "value is not an Element or null" unless value.is_a?(Dommy::Element)
  
          # set_attribute clears explicit refs via its aria-* hook, so store the
          # new reference afterward.
          set_attribute(content_attr, "")
          refs[key] = value
        end
        nil
      end

      # Read a plural ARIA element references value (a list of Elements): the
      # explicitly-set array wins; otherwise the content attribute is split as a
      # space-separated IDREF list and each resolved (missing ids dropped).
      def aria_elements_get(content_attr, key)
        # null when there are neither explicit elements nor a content attribute.
        return nil if aria_elements_current(content_attr, key).nil?
  
        # Otherwise a per-property memoized live list, so repeated reads return the
        # [SameObject] (WebIDL requires a stable FrozenArray) while its contents track
        # the current references/IDREFs.
        lists = (@aria_elements_lists ||= {})
        lists[key] ||= LiveNodeList.new { aria_elements_current(content_attr, key) || [] }
      end

      # Set a plural ARIA element references value: null/undefined clears it and
      # removes the content attribute; an array of Elements is stored and the
      # content attribute is set to the empty string.
      def aria_elements_set(content_attr, key, value)
        refs = (@aria_elements_refs ||= {})
        if value.nil? || (defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED))
          refs.delete(key)
          remove_attribute(content_attr) if @__node__.key?(content_attr)
        else
          # WebIDL: the value is a `sequence<Element>?` — a non-array, or an array
          # containing a non-Element, throws a TypeError.
          unless value.is_a?(Array) && value.all? { |el| el.is_a?(Dommy::Element) }
            raise Bridge::TypeError, "value is not a sequence of Elements"
          end
  
          set_attribute(content_attr, "")
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
        return nil unless @__node__.key?(content_attr)
  
        @__node__[content_attr].to_s.split(/[ \t\n\f\r]+/).reject(&:empty?).filter_map do |id|
          aria_find_in_root(id)
        end
      end

      # Resolve an ARIA IDREF within this element's tree ROOT (its topmost
      # ancestor) rather than the document — so references keep working when the
      # subtree is disconnected from the document.
      def aria_find_in_root(id)
        root = @__node__
        root = root.parent while root.parent && !root.parent.is_a?(Backend.document_class)
        node = ([root] + root.css("*").to_a).find { |n| n["id"].to_s == id }
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
