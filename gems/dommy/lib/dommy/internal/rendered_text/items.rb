# frozen_string_literal: true

module Dommy
  module Internal
    module RenderedText
      # The white-space values under which a run's spaces, tabs and newlines
      # collapse into one space.
      COLLAPSIBLE_WHITE_SPACE = %w[normal nowrap pre-line].freeze
      # The values under which a newline in the source stays a newline.
      NEWLINE_PRESERVING_WHITE_SPACE = %w[pre pre-wrap pre-line break-spaces].freeze
      # The values under which spaces and tabs stay as written.
      SPACE_PRESERVING_WHITE_SPACE = %w[pre pre-wrap break-spaces].freeze

      # The item list the collection steps produce holds four kinds of item.

      # A run of text as it appears in the item list, before the block-wide
      # white-space pass: the raw data plus the two computed properties that
      # decide how it renders.
      TextRun = Data.define(:text, :white_space, :text_transform) do
        def empty? = text.empty?

        def collapsible? = COLLAPSIBLE_WHITE_SPACE.include?(white_space)

        def preserves_newlines? = NEWLINE_PRESERVING_WHITE_SPACE.include?(white_space)

        def preserves_spaces? = SPACE_PRESERVING_WHITE_SPACE.include?(white_space)

        # Collapsible whitespace and nothing else: beside a block break it
        # neither shows nor separates anything.
        def collapsible_whitespace_only? = collapsible? && text.match?(/\A[ \t\n\r\f]*\z/)

        # The text with `text-transform` applied.
        def transformed_text
          case text_transform
          when "uppercase" then text.upcase
          when "lowercase" then text.downcase
          when "capitalize" then text.gsub(/\b\p{L}/) { |c| c.upcase }
          else text
          end
        end
      end

      # An atomic inline box (an inline-block or a replaced element): its own
      # rendered text, already collapsed and trimmed, which the surrounding
      # block treats as a single unbreakable unit.
      Atomic = Data.define(:text)

      # A string the collection steps append as is: "\n" for a <br>, "\t"
      # between table cells, "\n" between table rows.
      Literal = Data.define(:text)

      # A required line break count: the breaks around a block-level box (1)
      # or a <p> (2). Adjacent counts collapse to the largest.
      RequiredBreak = Data.define(:count)
    end
  end
end
