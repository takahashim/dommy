# frozen_string_literal: true

module Dommy
  module Internal
    # Computes an element's WAI-ARIA *accessible name* (the "accname"
    # algorithm) — what WPT's `test_driver.get_computed_label` returns and
    # Testing Library's name option matches. A focused implementation covering
    # the common steps: aria-labelledby, aria-label, native host-language
    # labels (<label>, alt), name-from-content for the roles that allow it, and
    # the title fallback. Name-from-content folds in CSS `::before` / `::after`
    # generated content (the accname algorithm requires it) — but only the text
    # components it can resolve without rendering: quoted strings and `attr()`.
    # `counter()` / `counters()`, bare `url()` images, and other layout-derived
    # content contribute nothing. Embedded control values are out of scope.
    module AccessibleName
      # Roles whose accessible name may come from descendant content. (term /
      # definition are nameFrom:author per ARIA, so they are NOT here.)
      NAME_FROM_CONTENT = %w[
        button cell checkbox columnheader comment gridcell heading
        link menuitem menuitemcheckbox menuitemradio option radio row rowheader
        sectionhead suggestion switch tab tooltip treeitem
      ].freeze

      # Form controls whose name can come from an associated <label>.
      LABELABLE = %w[button input meter output progress select textarea].freeze

      module_function

      # The accessible name string ("" when none). ASCII whitespace runs are
      # collapsed and the result trimmed, matching how browsers / Playwright
      # flatten an accessible name.
      def compute(element)
        squish(name_of(element, [], referenced: false, allow_content: false))
      end

      # Collapse ASCII whitespace runs to single spaces and trim.
      def squish(text)
        text.to_s.gsub(/\s+/, " ").strip
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

        # 6. Placeholder — the lowest-priority name source (below the title).
        placeholder = placeholder_fallback(node)
        return placeholder if placeholder

        ""
      end

      # aria-labelledby: join each referenced element's name. Returns nil when
      # the attribute is absent/empty (so the caller falls through).
      def labelledby_name(node, visited)
        referenced_names(node, "aria-labelledby", visited)
      end

      # Join the accessible names of the elements an IDREF-list attribute
      # (aria-labelledby / aria-describedby) points at. Returns nil when the
      # attribute is absent/empty or resolves to nothing, so the caller falls
      # through. Each referenced node is named with `referenced: true` (it does
      # not restart a labelledby traversal) and `allow_content: true`.
      def referenced_names(node, attribute, visited = [])
        ids = node.get_attribute(attribute).to_s.split(/\s+/).reject(&:empty?)
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
        when "figure"
          child_element_name(node, "figcaption", visited)
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

      # Input types for which the placeholder contributes the accessible name
      # (the text-like inputs); type=number / range / date / … do not.
      PLACEHOLDER_TYPES = %w[text search tel url email password].freeze

      def input_native_name(node, visited)
        type = node.get_attribute("type").to_s.downcase
        return node.get_attribute("alt") || node.get_attribute("value").to_s if type == "image"
        return node.get_attribute("value").to_s if %w[button submit reset].include?(type)

        label_text(node, visited)
      end

      # The placeholder names a text-like input / textarea, but only as the
      # lowest-priority source (below the title).
      def placeholder_fallback(node)
        tag = node.tag_name.to_s.downcase
        return placeholder_name(node) if tag == "textarea"
        return nil unless tag == "input"

        type = node.get_attribute("type").to_s.downcase
        (type.empty? || PLACEHOLDER_TYPES.include?(type)) ? placeholder_name(node) : nil
      end

      def placeholder_name(node)
        placeholder = node.get_attribute("placeholder").to_s
        placeholder.empty? ? nil : placeholder
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

      # Concatenate child text nodes and the names of element children, with the
      # `::before` content prepended and `::after` content appended (accname
      # name-from-content folds in generated content).
      def content_name(node, visited)
        bn = node.__dommy_backend_node__
        return "" unless bn.respond_to?(:children)

        children = bn.children.map do |child|
          if child.respond_to?(:text?) && child.text?
            child.text.to_s
          elsif child.respond_to?(:element?) && child.element?
            wrapped = node.document.wrap_node(child)
            next "" unless wrapped

            name = name_of(wrapped, visited, referenced: false, allow_content: true)
            # Concatenate contributions directly (inline content glues:
            # "button" + "" + "label" -> "buttonlabel"); a block-level box is
            # padded with spaces so sibling cells / blocks separate
            # ("Profile" + "A" -> "Profile A"). compute collapses the runs.
            block_level?(wrapped) ? " #{name} " : name
          else
            ""
          end
        end.join

        pseudo_content(node, "::before") + children + pseudo_content(node, "::after")
      end

      # Elements that generate a block-level box by the UA stylesheet — used as
      # the fallback when no CSS layer is available to compute `display`.
      BLOCK_TAGS = %w[
        address article aside blockquote caption dd details div dl dt fieldset
        figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr legend li main
        menu nav ol p pre section summary table tbody td tfoot th thead tr ul
      ].freeze

      # Whether an element generates a block-level box, so its text is separated
      # from siblings by whitespace in name-from-content (inline boxes glue). The
      # computed `display` decides when CSS is available (honoring author CSS);
      # otherwise the UA-default block-tag set is used so table cells / list
      # items still separate.
      def block_level?(element)
        display = computed_display(element)
        return BLOCK_TAGS.include?(element.local_name.to_s.downcase) if display.nil?

        !display.start_with?("inline") && !%w[none contents].include?(display)
      end

      def computed_display(element)
        value = Internal::CSS::Cascade.computed_style(element)["display"].to_s
        value.empty? ? nil : value
      rescue StandardError
        nil
      end

      # The text contribution of a `::before` / `::after` pseudo-element's
      # computed `content`. "" when the CSS layer is unavailable, the pseudo has
      # no generated content (`none` / `normal`), or its content is purely
      # non-text (counter/url/etc.).
      def pseudo_content(node, pseudo)
        return "" unless Internal::CSS::Parser.available?

        decl = Internal::CSS::ComputedStyleDeclaration.new(node, pseudo_element: pseudo)
        content_text(decl.get_property_value("content"), node)
      rescue StandardError
        ""
      end

      # Resolve a computed `content` value to its accname text. `counter()` /
      # `counters()` are resolved first (to quoted strings); then it scans for
      # the text-bearing components in order — quoted strings (CSS-unescaped) and
      # `attr(name)` (read off `node`) — and ignores everything else (`none` /
      # `normal`, `url()`, keywords). The image `/ "alt"` syntax is covered for
      # free: its alt string matches the quoted-string branch.
      def content_text(value, node)
        v = value.to_s.strip
        return "" if v.empty? || v == "none" || v == "normal"

        if v.match?(/\bcounters?\(/i)
          v = Internal::CSS::Counters.substitute(v, Internal::CSS::Cascade.counter_values(node))
        end

        text = +""
        v.scan(/"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|attr\(\s*([-\w]+)\s*\)/) do
          dq, sq, attr = Regexp.last_match.captures
          text << (attr ? node.get_attribute(attr).to_s : unescape_css_string(dq || sq))
        end
        text
      end

      # CSS string unescaping: `\HEX ` → the code point, `\<char>` → the char.
      def unescape_css_string(str)
        str.gsub(/\\(?:([0-9a-fA-F]{1,6})[ \t\n]?|(.))/) do
          hex = Regexp.last_match(1)
          hex ? [hex.to_i(16)].pack("U") : Regexp.last_match(2)
        end
      end
    end
  end
end
