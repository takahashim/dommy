# frozen_string_literal: true

module Dommy
  module Internal
    # Computes an element's WAI-ARIA *accessible name* (the "accname"
    # algorithm) — what WPT's `test_driver.get_computed_label` returns and
    # Testing Library's name option matches. A focused implementation covering
    # the common steps: aria-labelledby, aria-label, native host-language
    # labels (<label>, alt), name-from-content for the roles that allow it, and
    # the title fallback. Layout/CSS-derived names (pseudo-content) and embedded
    # control values are out of scope.
    module AccessibleName
      # Roles whose accessible name may come from descendant content.
      NAME_FROM_CONTENT = %w[
        button cell checkbox columnheader comment definition gridcell heading
        link menuitem menuitemcheckbox menuitemradio option radio row rowheader
        sectionhead suggestion switch tab tooltip term treeitem
      ].freeze

      # Form controls whose name can come from an associated <label>.
      LABELABLE = %w[button input meter output progress select textarea].freeze

      module_function

      # The accessible name string ("" when none). The harness normalizes ASCII
      # whitespace and trims, so internal spacing need only be roughly correct.
      def compute(element)
        name_of(element, [], referenced: false, allow_content: false).strip
      end

      # `referenced`: this node was reached through aria-labelledby, so it must
      # not start a fresh labelledby traversal (prevents loops, and lets a
      # self-reference fall through to its own aria-label/content).
      # `allow_content`: name-from-content is permitted regardless of role (true
      # for referenced and recursed-into nodes); at the top it is role-gated.
      def name_of(node, visited, referenced:, allow_content:)
        return "" unless node.respond_to?(:__dommy_backend_node__)

        # 1. aria-labelledby (not when already inside a labelledby traversal).
        unless referenced
          labelled = labelledby_name(node, visited)
          return labelled unless labelled.nil?
        end

        # 2. aria-label.
        aria_label = node.get_attribute("aria-label").to_s
        return aria_label unless aria_label.strip.empty?

        # 3. Native host-language labeling.
        native = native_name(node, visited)
        return native unless native.nil?

        # 4. Name from content (role-permitting, or when recursing). Guard
        #    against content cycles with the visited set.
        key = node.__dommy_backend_node__
        if (allow_content || NAME_FROM_CONTENT.include?(node.computed_role)) && visited.none? { |v| v.equal?(key) }
          content = content_name(node, visited + [key])
          # Preserve whitespace-only content: a space deep in the subtree is the
          # separator between sibling text runs ("button" + " " + "label").
          return content unless content.empty?
        end

        # 5. Tooltip (title) fallback.
        title = node.get_attribute("title").to_s
        return title unless title.empty?

        ""
      end

      # aria-labelledby: join each referenced element's name. Returns nil when
      # the attribute is absent/empty (so the caller falls through).
      def labelledby_name(node, visited)
        ids = node.get_attribute("aria-labelledby").to_s.split(/\s+/).reject(&:empty?)
        return nil if ids.empty?

        doc = node.respond_to?(:document) ? node.document : nil
        return nil unless doc

        parts = ids.map do |id|
          ref = doc.get_element_by_id(id)
          ref ? name_of(ref, visited, referenced: true, allow_content: true) : ""
        end
        joined = parts.join(" ").strip
        joined.empty? ? nil : joined
      end

      # <label>/alt host-language names. Returns nil when not applicable.
      def native_name(node, visited)
        tag = node.tag_name.to_s.downcase
        case tag
        when "img", "area"
          alt = node.get_attribute("alt")
          alt.nil? ? nil : alt
        when "input"
          input_native_name(node, visited)
        when "fieldset"
          child_element_name(node, "legend", visited)
        when "table"
          child_element_name(node, "caption", visited)
        when *LABELABLE
          label_text(node, visited)
        end
      end

      # The name of the first child element with the given tag (e.g. a
      # <fieldset>'s <legend>, a <table>'s <caption>). nil when absent.
      def child_element_name(node, tag, visited)
        bn = node.__dommy_backend_node__
        return nil unless bn.respond_to?(:children)

        child = bn.children.find { |c| c.respond_to?(:name) && c.name.to_s.casecmp?(tag) }
        return nil unless child

        name_of(node.document.wrap_node(child), visited, referenced: false, allow_content: true)
      end

      def input_native_name(node, visited)
        type = node.get_attribute("type").to_s.downcase
        return node.get_attribute("alt") || node.get_attribute("value").to_s if type == "image"
        return node.get_attribute("value").to_s if %w[button submit reset].include?(type)

        label_text(node, visited)
      end

      # The concatenated text of the <label>s associated with a control:
      # label[for=id] anywhere, plus an ancestor <label>. nil → no labels.
      def label_text(node, visited)
        labels = associated_labels(node)
        return nil if labels.empty?

        text = labels.map { |l| name_of(l, visited, referenced: false, allow_content: true) }.join(" ").strip
        text.empty? ? nil : text
      end

      def associated_labels(node)
        labels = []
        id = node.get_attribute("id").to_s
        unless id.empty?
          doc = node.document
          labels.concat(doc.query_selector_all("label[for='#{id}']").to_a) if doc
        end
        ancestor = closest_label(node)
        labels << ancestor if ancestor && !labels.include?(ancestor)
        labels
      end

      def closest_label(node)
        bn = node.__dommy_backend_node__&.parent
        while bn.respond_to?(:name)
          return node.document.wrap_node(bn) if bn.name.to_s.casecmp?("label")

          bn = bn.parent
        end
        nil
      end

      # Concatenate child text nodes and the names of element children.
      def content_name(node, visited)
        bn = node.__dommy_backend_node__
        return "" unless bn.respond_to?(:children)

        bn.children.map do |child|
          if child.respond_to?(:text?) && child.text?
            child.text.to_s
          elsif child.respond_to?(:element?) && child.element?
            wrapped = node.document.wrap_node(child)
            wrapped ? name_of(wrapped, visited, referenced: false, allow_content: true) : ""
          else
            ""
          end
        end.join
      end
    end
  end
end
