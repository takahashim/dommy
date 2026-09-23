# frozen_string_literal: true

module Dommy
  module Internal
    # The backend pre-filter behind SelectorMatcher#fast_query.
    #
    # The Ruby matcher wraps every descendant into a Dommy element before
    # matching, so a `.foo` query over a 5000-element tree wraps all 5000 to
    # return the 50 matches. This walks the backend (lexbor) nodes directly and
    # gates each by a cheap static check taken from the subject compound — its
    # id, class, attribute or tag — read straight off the backend node.
    #
    # Every check here is a SUPERSET of what the selector requires, never a
    # false negative, so SelectorMatcher#matches? — which remains the authority
    # on combinators, pseudo-classes, case and namespace — yields exactly the
    # same set in the same order.
    module BackendPrefilter
      module_function

      # Every descendant ELEMENT of the backend node `bnode`, in document order,
      # excluding `bnode` itself — walking lexbor nodes directly via the
      # first-child / next-sibling chain (no Dommy wrap and, unlike
      # `element_children`, no per-node NodeSet allocation, which dominated GC).
      # A tree is entirely one backend's nodes, so the capability test runs once
      # per query here rather than once per node inside the walk.
      def each_backend_descendant(bnode, &block)
        if bnode.respond_to?(:first_element_child)
          each_backend_element_descendant(bnode, &block)
        else
          each_backend_child_list_descendant(bnode, &block)
        end
      end

      def each_backend_element_descendant(bnode, &block)
        child = bnode.first_element_child
        while child
          block.call(child)
          each_backend_element_descendant(child, &block)
          # `next_element` is the backend's native (C) element-only sibling step;
          # it skips intervening text/comment nodes in one call, where a Ruby
          # `.next`-until-element loop cost ~6% of a heavy page's wall time.
          child = child.next_element
        end
      end

      # The XML backend has no first_element_child / next_element sibling walk
      # (a Document there answers neither); its `element_children` list is the
      # equivalent, at the cost of materializing one array per level. Same
      # guard as Internal::SelectorIndex#populate.
      def each_backend_child_list_descendant(bnode, &block)
        bnode.element_children.each do |child|
          block.call(child)
          each_backend_child_list_descendant(child, &block)
        end
      end

      # One [kind, value] pre-filter per complex selector — taken from its subject
      # (rightmost) compound. nil when ANY subject lacks a static id/class/attribute
      # to filter on (a universal- or pseudo-only subject), so the whole query
      # falls back to the Ruby matcher.
      def static_prefilters(selector_ast)
        selector_ast.selectors.map do |complex|
          compound = complex.parts.last.compound
          return nil if compound.pseudo_element

          prefilter_for(compound) || (return nil)
        end
      end

      # The most selective static check in `compound` (id > class > attribute >
      # type); nil if it has none (universal/pseudo-only subject). The exact
      # case/namespace and pseudo state are still left to the authoritative
      # #matches? — the prefilter only has to be a SUPERSET.
      def prefilter_for(compound)
        id = klass = attr = nil
        compound.subclass_selectors.each do |sub|
          case sub
          when SelectorAST::IdSelector then id ||= sub.value
          when SelectorAST::ClassSelector then klass ||= sub.value
          when SelectorAST::AttributeSelector then attr ||= sub.name if sub.namespace.nil?
          end
        end
        return [:id, id] if id
        return [:class, klass] if klass
        return [:attr, attr] if attr

        # A concrete tag (`a`, `div span`) gates the backend walk by tag name —
        # without it a type-only subject wraps EVERY element before matching,
        # which dominated a jQuery-heavy page (`$.find('div a')`). Case/namespace
        # exactness is matches?'s job, so this is a (case-insensitive) superset.
        type = compound.type
        return [:type, type.name.to_s] if type.is_a?(SelectorAST::TypeSelector) && !type.name.to_s.empty?

        nil
      end

      # [:class|:id, value] when `compound` is EXACTLY one class or id selector
      # (no type, no pseudo, nothing else), else nil. For such a compound the index
      # lookup is an exact match — not just a superset — so an index "does an
      # ancestor match?" answer can be trusted without re-running matches_compound?.
      def exact_class_or_id_prefilter(compound)
        return nil unless compound.type.nil? && compound.pseudo_element.nil?

        subs = compound.subclass_selectors
        return nil unless subs.size == 1

        case subs.first
        when SelectorAST::ClassSelector then [:class, subs.first.value]
        when SelectorAST::IdSelector then [:id, subs.first.value]
        end
      end

      # Does the backend node satisfy a pre-filter? A SUPERSET test (presence /
      # exact id / class token / tag) — never a false negative, so #matches? can prune.
      def backend_passes?(bnode, prefilter)
        kind, value = prefilter
        case kind
        when :id then bnode["id"] == value
        when :class then class_attr_token?(bnode["class"], value)
        when :attr then !bnode[value].nil?
        when :type then (name = bnode.name) && name.casecmp?(value)
        end
      end

      # Is `token` a whitespace-separated word of the raw class attribute? Scans in
      # place (no split/allocation), since this runs for every node in the tree.
      def class_attr_token?(raw, token)
        return false if raw.nil? || raw.empty?

        pos = 0
        len = token.length
        while (i = raw.index(token, pos))
          before = i.zero? || ascii_ws?(raw[i - 1])
          after_index = i + len
          after = after_index >= raw.length || ascii_ws?(raw[after_index])
          return true if before && after

          pos = i + 1
        end
        false
      end

      def ascii_ws?(char)
        char == " " || char == "\t" || char == "\n" || char == "\f" || char == "\r"
      end

      # The backend (lexbor) node whose subtree holds the candidates.
      def backend_root_of(root)
        if root.is_a?(Document)
          root.backend_doc
        elsif root.respond_to?(:__dommy_backend_node__)
          root.__dommy_backend_node__
        end
      end

      # The owning Document (for identity-stable #wrap_node of a backend match).
      def document_of(root)
        return root if root.is_a?(Document)

        root.document if root.respond_to?(:document)
      end
    end
  end
end
