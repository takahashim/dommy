# frozen_string_literal: true

require_relative "css/cascade"
require_relative "css/renderability"
require_relative "css/ua_stylesheet"

module Dommy
  module Internal
    # HTML's `innerText` / `outerText`: the "rendered text collection steps"
    # (the getter) and the "rendered text fragment" (the setter), from
    # https://html.spec.whatwg.org/multipage/dom.html#the-innertext-and-outertext-properties
    #
    # Dommy lays nothing out, so the layout-derived parts — soft line wrapping,
    # `::first-line` / `::first-letter`, multicol — are out of reach. Everything
    # that follows from the computed style and the tree is implemented:
    # display:none / contents, visibility, white-space, text-transform, <br>,
    # block and <p> line breaks, table cells and rows, and the select /
    # optgroup / option box rules.
    module RenderedText
      # Elements that render as a replaced box, whose children are not rendered
      # at all: innerText falls back to textContent for their descendants.
      REPLACED = %w[area audio canvas embed iframe img input object textarea video].freeze

      # The elements the spec gives a special box for inside <select>.
      OPTION_LIKE = %w[optgroup option].freeze

      # The block-level box fallback when no CSS layer is available.
      BLOCK_TAGS = CSS::UAStylesheet::BLOCK_LEVEL_TAGS

      # A run of text as it appears in the item list, before the block-wide
      # white-space pass: the raw data plus the two computed properties that
      # decide how it collapses.
      TextRun = Struct.new(:text, :white_space, :transform)

      # An atomic inline box (an inline-block or a replaced element): its own
      # rendered text, already collapsed and trimmed, which the surrounding
      # block treats as a single unbreakable unit.
      Atomic = Struct.new(:text)

      module_function

      # The getter: HTML's "get the text steps".
      def get(element)
        return element.text_content.to_s if text_content_fallback?(element)

        items = element.child_nodes.to_a.flat_map { |child| collect(child) }
        to_string(items)
      end

      # The innerText setter: "set the inner text steps".
      def set_inner(element, value)
        element.__internal_replace_all__(fragment(element.document, value.to_s).map(&:__dommy_backend_node__))
        nil
      end

      # The outerText setter.
      def set_outer(element, value)
        raise DOMException::NoModificationAllowedError, "outerText requires a parent" if element.parent_node.nil?

        following = element.next_sibling
        preceding = element.previous_sibling
        nodes = fragment(element.document, value.to_s)
        nodes = [element.document.create_text_node("")] if nodes.empty?
        element.replace_with(*nodes)
        merge_next_text_node(following)
        merge_next_text_node(preceding) if preceding.is_a?(TextNode)
        nil
      end

      # The "rendered text fragment": split on line breaks, a Text node between
      # them and a <br> for each run of breaks.
      def fragment(document, value)
        out = []
        buffer = +""
        chars = value.chars
        position = 0
        while position < chars.length
          char = chars[position]
          if char == "\n" || char == "\r"
            out << document.create_text_node(buffer) unless buffer.empty?
            buffer = +""
            position += 1 if char == "\r" && chars[position + 1] == "\n"
            out << document.create_element("br")
          else
            buffer << char
          end
          position += 1
        end
        out << document.create_text_node(buffer) unless buffer.empty?
        out
      end

      # --- the rendered text collection steps ---------------------------------

      def collect(node)
        if text_node?(node)
          return [] unless visible?(node)
          return [] if not_being_rendered?(node)

          return [text_run(node)]
        end
        # A Comment / ProcessingInstruction carries no rendered text and has no
        # child list to walk.
        return [] unless node.respond_to?(:child_nodes)

        items = collect_children(node)
        return items unless visible?(node)
        return items if not_being_rendered?(node)
        # An atomic inline renders as one unbreakable box: a replaced element
        # contributes nothing, an inline-block contributes its own (already
        # collapsed) text, and whitespace on either side does not merge with
        # what is inside. Block-level replaced elements still get line breaks
        # below.
        if replaced_element?(node) && inline_level?(node)
          return [Atomic.new("")]
        elsif atomic_container?(node)
          return [Atomic.new(to_string(collect_children(node)))]
        end

        items << "\n" if local_name?(node, "br")
        items << "\t" if table_cell_not_last?(node)
        items << "\n" if table_row_not_last?(node)
        if local_name?(node, "p")
          items.unshift(2)
          items.push(2)
        elsif block_level?(node)
          items.unshift(1)
          items.push(1)
        end
        items
      end

      def collect_children(node)
        children = node.child_nodes.to_a
        # A <select> box's children are only its optgroup / option descendants;
        # text and other elements directly inside it are not rendered.
        children = children.select { |c| option_like?(c) } if local_name?(node, "select") && rendered?(node)
        children.flat_map { |child| collect(child) }
      end

      def text_run(node)
        style = style_of(node)
        TextRun.new(node.data.to_s, style["white-space"].to_s, style["text-transform"].to_s)
      end

      # --- the block-wide white-space pass ------------------------------------

      # Collapse the item list into the final string. The item list is first
      # normalized (see #normalize_items), then each item is fed to a
      # WhitespaceCollapser, which owns the block-wide white-space state.
      def to_string(items)
        collapser = WhitespaceCollapser.new
        normalize_items(items).each { |item| collapser.append(item) }
        collapser.result
      end

      # Drop empty runs, drop a whitespace-only run beside a block break (the
      # collapsible whitespace around a block box neither shows nor separates
      # the two breaks), trim the leading/trailing required-line-break runs, and
      # collapse each run of them to the largest count.
      def normalize_items(items)
        items = items.reject { |item| item.is_a?(TextRun) && item.text.empty? }
        items = items.each_with_index.reject do |item, i|
          collapsible_whitespace_only?(item) &&
            ((i.positive? && items[i - 1].is_a?(Integer)) ||
             (i + 1 < items.length && items[i + 1].is_a?(Integer)))
        end.map { |item, _| item }
        items.shift while items.first.is_a?(Integer)
        items.pop while items.last.is_a?(Integer)

        collapsed = []
        items.each do |item|
          if item.is_a?(Integer) && collapsed.last.is_a?(Integer)
            collapsed[-1] = [collapsed[-1], item].max
          else
            collapsed << item
          end
        end
        collapsed
      end

      def transform_text(text, transform)
        case transform
        when "uppercase" then text.upcase
        when "lowercase" then text.downcase
        when "capitalize" then text.gsub(/\b\p{L}/) { |c| c.upcase }
        else text
        end
      end

      # The block-wide white-space pass over the normalized item list. Its three
      # pieces of state are the whole algorithm:
      #   * `pending_space` — a collapsible space seen but not yet emitted (it is
      #     dropped if nothing follows on the line);
      #   * `line_start` — suppresses that space at the start of a line;
      #   * `after_atomic` — makes the space following an atomic inline literal,
      #     so whitespace on either side of an inline-block does not merge.
      class WhitespaceCollapser
        def initialize
          @out = +""
          @pending_space = false
          @line_start = true
          @after_atomic = false
        end

        def result = @out

        def append(item)
          case item
          when Integer then append_breaks(item)
          when String then append_literal(item)
          when Atomic then append_atomic(item)
          else append_run(item)
          end
        end

        private

        # A required-line-break count: emit that many newlines and start a line.
        def append_breaks(breaks)
          @out << ("\n" * breaks)
          @pending_space = false
          @line_start = true
          @after_atomic = false
        end

        # A literal hard break the collection steps appended: "\n" for a <br>,
        # "\t" between table cells.
        def append_literal(text)
          @out << text
          @pending_space = false
          @line_start = text == "\n"
          @after_atomic = false
        end

        def append_atomic(atomic)
          @out << " " if @pending_space
          @out << atomic.text
          @pending_space = false
          @line_start = false
          @after_atomic = true
        end

        def append_run(run)
          text = RenderedText.transform_text(run.text, run.transform)
          collapse = %w[normal nowrap pre-line].include?(run.white_space)
          preserve_newlines = %w[pre pre-wrap pre-line break-spaces].include?(run.white_space)
          preserve_spaces = %w[pre pre-wrap break-spaces].include?(run.white_space)
          text.each_char do |char|
            case char
            when "\n", "\r" then append_newline(collapse, preserve_newlines)
            when " ", "\t", "\f" then append_space(char, preserve_spaces)
            else append_char(char)
            end
          end
        end

        def append_newline(collapse, preserve)
          if preserve
            @out << "\n"
            @pending_space = false
            @line_start = true
          elsif collapse
            @pending_space = true
          end
        end

        def append_space(char, preserve)
          if preserve
            @out << char
            @pending_space = false
            @line_start = false
          elsif @after_atomic
            @out << " "
            @after_atomic = false
          else
            @pending_space = true
          end
        end

        def append_char(char)
          if @pending_space && !@line_start && !@out.end_with?(" ", "\n", "\t")
            @out << " "
          end
          @pending_space = false
          @after_atomic = false
          @out << char
          @line_start = false
        end
      end

      # --- node predicates ----------------------------------------------------

      def text_node?(node) = node.is_a?(TextNode)

      def local_name?(node, name)
        node.respond_to?(:local_name) && node.local_name.to_s.casecmp?(name)
      end

      def option_like?(node) = OPTION_LIKE.any? { |name| local_name?(node, name) }

      def replaced_element?(node) = REPLACED.any? { |name| local_name?(node, name) }

      def inline_level?(node)
        display = display_of(node)
        display.empty? || display.start_with?("inline")
      end

      # An atomic inline-level container: it establishes its own inline
      # formatting context, so its leading/trailing whitespace is trimmed and
      # the whitespace around it does not merge with its content.
      def atomic_container?(node)
        return false unless node.respond_to?(:local_name)
        # A <p> keeps its two line breaks whatever its display.
        return false if local_name?(node, "p")

        %w[inline-block inline-flex inline-grid inline-table].include?(display_of(node))
      end

      def collapsible_whitespace_only?(item)
        return false unless item.is_a?(TextRun)
        return false unless %w[normal nowrap pre-line].include?(item.white_space)

        item.text.match?(/\A[ \t\n\r\f]*\z/)
      end

      def rendered?(element)
        !unrendered?(element)
      end

      # Not rendered by tree position (disconnected, outside the flat tree, a
      # non-rendered frame) or by an ancestor: display:none, or content other
      # than the first <summary> of a closed <details>.
      def unrendered?(element)
        CSS::Renderability.not_rendered?(element, method(:style)) || hidden_ancestor?(element)
      end

      # The getter falls back to textContent for an element that is not being
      # rendered or is a descendant of a replaced element, whose children are
      # not rendered.
      def text_content_fallback?(element)
        return true unless rendered?(element)

        replaced_ancestor?(element, include_self: false)
      end

      def replaced_ancestor?(element, include_self:)
        node = include_self ? element : element.parent_element
        while node.respond_to?(:local_name)
          return true if REPLACED.any? { |name| local_name?(node, name) }

          node = node.parent_element
        end
        false
      end

      def visible?(node)
        style_of(node)["visibility"].to_s == "visible"
      end

      def not_being_rendered?(node)
        element = text_node?(node) ? node.parent_element : node
        return true unless element.respond_to?(:local_name)
        return true if unrendered?(element)
        return true if replaced_ancestor?(element, include_self: text_node?(node))
        # display:contents has no box, but its children do — so it is not being
        # rendered itself while a text child of it still is.
        return false if text_node?(node)

        display_of(node) == "contents"
      end

      # An element hidden by an ancestor: a display:none subtree, or content
      # other than the first <summary> inside a closed <details>.
      def hidden_ancestor?(element)
        node = element
        while node.respond_to?(:local_name)
          return true if display_of(node) == "none"
          return true if closed_details_hides?(node, element)

          node = node.parent_element
        end
        false
      end

      def closed_details_hides?(ancestor, element)
        return false unless local_name?(ancestor, "details") && !ancestor.has_attribute?("open")

        summary = element_children(ancestor).find { |c| local_name?(c, "summary") }
        !(summary && summary.contains?(element))
      end

      def display_of(element)
        style_of(element)["display"].to_s
      end

      def block_level?(node)
        return false unless node.respond_to?(:local_name)
        # <p> is handled by the caller (2 breaks); optgroup / option act as
        # block-level boxes whatever their computed display.
        return true if option_like?(node)

        display = display_of(node)
        return BLOCK_TAGS.include?(node.local_name.to_s.downcase) if display.empty?
        return false if %w[contents none].include?(display)
        return false if display == "table-cell" || display == "table-row"

        !display.start_with?("inline")
      end

      def table_cell_not_last?(node)
        return false unless display_of(node) == "table-cell"

        row = node.parent_element
        return false unless row

        cells = element_children(row).select { |c| display_of(c) == "table-cell" }
        !cells.empty? && !cells.last.equal?(node)
      end

      def table_row_not_last?(node)
        return false unless display_of(node) == "table-row"

        table = node.parent_element
        table = table.parent_element while table && display_of(table) == "table-row-group"
        return false unless table

        rows = table_rows(table)
        !rows.empty? && !rows.last.equal?(node)
      end

      # Every table-row box of a table, in tree order, descending through the
      # row groups (tbody / thead / tfoot) but not into a nested table.
      def table_rows(table)
        rows = []
        collect = lambda do |parent|
          element_children(parent).each do |child|
            case display_of(child)
            when "table-row" then rows << child
            when "table-row-group" then collect.call(child)
            end
          end
        end
        collect.call(table)
        rows
      end

      def element_children(node)
        node.child_nodes.to_a.select { |c| c.respond_to?(:local_name) }
      end

      def style_of(node)
        element = text_node?(node) ? node.parent_element : node
        return {} unless element.respond_to?(:local_name)

        style(element)
      end

      def style(element)
        CSS::Cascade.computed_style(element)
      rescue CSS::Parser::Unavailable
        {}
      end

      # --- text node merging (outerText setter) -------------------------------

      def merge_next_text_node(node)
        return unless node.is_a?(TextNode)

        following = node.next_sibling
        return unless following.is_a?(TextNode)

        node.data = node.data + following.data
        following.remove
      end
    end
  end
end
