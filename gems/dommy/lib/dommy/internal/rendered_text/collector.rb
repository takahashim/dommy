# frozen_string_literal: true

require_relative "../css/cascade"
require_relative "../css/renderability"
require_relative "../css/ua_stylesheet"
require_relative "computed_box"
require_relative "items"
require_relative "whitespace_collapser"

module Dommy
  module Internal
    module RenderedText
      # The `innerText` / `outerText` getter: HTML's "rendered text collection
      # steps", from
      # https://html.spec.whatwg.org/multipage/dom.html#the-innertext-and-outertext-properties
      #
      # Dommy lays nothing out, so the layout-derived parts — soft line
      # wrapping, `::first-line` / `::first-letter`, multicol — are out of
      # reach. Everything that follows from the computed style and the tree is
      # implemented: display:none / contents, visibility, white-space,
      # text-transform, <br>, block and <p> line breaks, table cells and rows,
      # and the select / optgroup / option box rules.
      #
      # Whether the element itself is rendered is asked once, up the tree.
      # Below it the walk goes top-down and never looks up again: a subtree
      # without a box is skipped where it starts (see #collect_element and
      # #rendered_children).
      class Collector
        # Elements that render as a replaced box, whose children are not
        # rendered at all.
        REPLACED = %w[area audio canvas embed iframe img input object textarea video].freeze

        # The elements the spec gives a special box for inside <select>.
        OPTION_LIKE = %w[optgroup option].freeze

        # Displays that make an atomic inline-level box: it establishes its own
        # inline formatting context, so its leading/trailing whitespace is
        # trimmed and the whitespace around it does not merge with its content.
        ATOMIC_INLINE_DISPLAYS = %w[inline-block inline-flex inline-grid inline-table].freeze

        def initialize(element)
          @element = element
          @boxes = {}.compare_by_identity
        end

        # HTML's "get the text steps": textContent for an element that is not
        # being rendered, the rendered text otherwise.
        def text
          return @element.text_content.to_s unless being_rendered?(@element)

          WhitespaceCollapser.collapse(collect_children(@element))
        end

        private

        # Rendered by tree position (connected, in the flat tree, in a rendered
        # frame), and reached from the root only through boxes that render it:
        # no display:none on the way, and each step down one that
        # #rendered_children keeps — which is what rules out a replaced
        # ancestor and the hidden content of a closed <details>.
        def being_rendered?(element)
          return false if CSS::Renderability.not_rendered?(element, method(:style))

          node = element
          while node
            return false if box(node).none?

            parent = node.parent_element
            return false if parent && rendered_children(parent).none? { |child| child.equal?(node) }

            node = parent
          end
          true
        end

        # --- the rendered text collection steps -----------------------------

        def collect(node)
          case node
          when TextNode then collect_text(node)
          when Element then collect_element(node)
          else [] # a Comment / ProcessingInstruction carries no rendered text
          end
        end

        def collect_text(node)
          box = box(node.parent_element)
          return [] unless box.visible?

          [TextRun.new(node.data.to_s, box.white_space, box.text_transform)]
        end

        def collect_element(element)
          box = box(element)
          # Nothing inside a display:none box is rendered.
          return [] if box.none?

          items = collect_children(element)
          # Invisible, or no box of its own (display:contents): the children's
          # items alone.
          return items if !box.visible? || box.contents?
          # An atomic inline renders as one unbreakable box: a replaced element
          # contributes nothing, an inline-block contributes its own (already
          # collapsed) text, and whitespace on either side does not merge with
          # what is inside. Block-level replaced elements still get line breaks
          # below.
          return [Atomic.new("")] if replaced?(element) && box.inline_level?
          return [Atomic.new(WhitespaceCollapser.collapse(items))] if atomic_inline?(element, box)

          items << Literal.new("\n") if tag(element) == "br"
          items << Literal.new("\t") if table_cell_not_last?(element, box)
          items << Literal.new("\n") if table_row_not_last?(element, box)
          breaks = required_breaks(element, box)
          breaks ? [RequiredBreak.new(breaks), *items, RequiredBreak.new(breaks)] : items
        end

        def collect_children(element)
          rendered_children(element).flat_map { |child| collect(child) }
        end

        # The child nodes that get a box, where the element restricts them: a
        # replaced element renders none, a <select> only its optgroup / option
        # children, a closed <details> only its first <summary>, and a shadow
        # host only the children assigned to a slot.
        def rendered_children(element)
          children = element.child_nodes.to_a
          if replaced?(element)
            []
          elsif tag(element) == "select"
            children.select { |child| option_like?(child) }
          elsif closed_details?(element)
            summary = children.grep(Element).find { |child| tag(child) == "summary" }
            summary ? [summary] : []
          elsif element.shadow_root
            children.select { |child| child.respond_to?(:assigned_slot) && child.assigned_slot }
          else
            children
          end
        end

        # A <p> gets two required line breaks whatever its display, any other
        # block-level box one.
        def required_breaks(element, box)
          if tag(element) == "p" then 2
          elsif block_level?(element, box) then 1
          end
        end

        # optgroup / option act as block-level boxes whatever their computed
        # display; table cells and rows are separated by tabs and newlines
        # instead. With no computed display, the UA-default box decides.
        def block_level?(element, box)
          return true if option_like?(element)
          return CSS::UAStylesheet::BLOCK_LEVEL_TAGS.include?(tag(element)) if box.display.nil?
          return false if box.display == "table-cell" || box.display == "table-row"

          !box.inline_level?
        end

        # A <p> keeps its two line breaks whatever its display.
        def atomic_inline?(element, box)
          tag(element) != "p" && ATOMIC_INLINE_DISPLAYS.include?(box.display)
        end

        def table_cell_not_last?(element, box)
          return false unless box.display == "table-cell"

          row = element.parent_element
          return false unless row

          cells = element_children(row).select { |child| box(child).display == "table-cell" }
          !cells.last.equal?(element)
        end

        def table_row_not_last?(element, box)
          return false unless box.display == "table-row"

          table = element.parent_element
          table = table.parent_element while table && box(table).display == "table-row-group"
          return false unless table

          !table_rows(table).last.equal?(element)
        end

        # Every table-row box of a table, in tree order, descending through the
        # row groups (tbody / thead / tfoot) but not into a nested table.
        def table_rows(parent)
          element_children(parent).flat_map do |child|
            case box(child).display
            when "table-row" then [child]
            when "table-row-group" then table_rows(child)
            else []
            end
          end
        end

        # --- element facts --------------------------------------------------

        def tag(element) = element.local_name.to_s.downcase

        def replaced?(element) = REPLACED.include?(tag(element))

        def option_like?(node) = node.is_a?(Element) && OPTION_LIKE.include?(tag(node))

        def closed_details?(element) = tag(element) == "details" && !element.has_attribute?("open")

        def element_children(element) = element.child_nodes.to_a.grep(Element)

        def box(element)
          @boxes[element] ||= ComputedBox.from(style(element))
        end

        def style(element)
          CSS::Cascade.computed_style(element)
        rescue CSS::Parser::Unavailable
          {}
        end
      end
    end
  end
end
