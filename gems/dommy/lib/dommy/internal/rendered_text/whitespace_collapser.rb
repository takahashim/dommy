# frozen_string_literal: true

require_relative "items"

module Dommy
  module Internal
    module RenderedText
      # The block-wide white-space pass: turns the item list into the final
      # string. The list is first normalized (see #normalize), then each item
      # is appended in turn. Its three pieces of state are the whole algorithm:
      #   * `pending_space` — a collapsible space seen but not yet emitted (it is
      #     dropped if nothing follows on the line);
      #   * `line_start` — suppresses that space at the start of a line;
      #   * `after_atomic` — makes the space following an atomic inline literal,
      #     so whitespace on either side of an inline-block does not merge.
      class WhitespaceCollapser
        def self.collapse(items) = new.collapse(items)

        def initialize
          @out = +""
          @pending_space = false
          @line_start = true
          @after_atomic = false
        end

        def collapse(items)
          normalize(items).each { |item| append(item) }
          @out
        end

        private

        # Drop empty runs, drop a collapsible whitespace-only run beside a
        # required break (the whitespace around a block box neither shows nor
        # separates the two breaks), trim the leading/trailing required breaks,
        # and collapse each run of them to the largest count.
        def normalize(items)
          items = items.reject { |item| item.is_a?(TextRun) && item.empty? }
          items = items.reject.with_index do |item, i|
            item.is_a?(TextRun) && item.collapsible_whitespace_only? &&
              (required_break_at?(items, i - 1) || required_break_at?(items, i + 1))
          end
          items.shift while items.first.is_a?(RequiredBreak)
          items.pop while items.last.is_a?(RequiredBreak)

          items.chunk_while { |a, b| a.is_a?(RequiredBreak) && b.is_a?(RequiredBreak) }.map do |chunk|
            chunk.first.is_a?(RequiredBreak) ? RequiredBreak.new(chunk.map(&:count).max) : chunk.first
          end
        end

        def required_break_at?(items, index)
          index >= 0 && items[index].is_a?(RequiredBreak)
        end

        def append(item)
          case item
          when RequiredBreak then append_breaks(item.count)
          when Literal then append_literal(item.text)
          when Atomic then append_atomic(item.text)
          when TextRun then append_run(item)
          end
        end

        # Emit that many newlines and start a line.
        def append_breaks(count)
          @out << ("\n" * count)
          @pending_space = false
          @line_start = true
          @after_atomic = false
        end

        def append_literal(text)
          @out << text
          @pending_space = false
          @line_start = text == "\n"
          @after_atomic = false
        end

        def append_atomic(text)
          @out << " " if @pending_space
          @out << text
          @pending_space = false
          @line_start = false
          @after_atomic = true
        end

        def append_run(run)
          run.transformed_text.each_char do |char|
            case char
            when "\n", "\r" then append_newline(run)
            when " ", "\t", "\f" then append_space(char, run)
            else append_char(char)
            end
          end
        end

        def append_newline(run)
          if run.preserves_newlines?
            @out << "\n"
            @pending_space = false
            @line_start = true
          elsif run.collapsible?
            @pending_space = true
          end
        end

        def append_space(char, run)
          if run.preserves_spaces?
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
    end
  end
end
