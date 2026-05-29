# frozen_string_literal: true

module Dommy
  module Rack
    # Browser-tab-style navigation history: an ordered stack of visited URLs
    # with a cursor. Visiting a new URL truncates any forward entries.
    class History
      def initialize
        @stack = []
        @index = -1
      end

      def push(url)
        kept = @index >= 0 ? @stack[0..@index] : []
        @stack = kept + [url]
        @index = @stack.size - 1
        url
      end

      # Move the cursor back one entry and return that URL, or nil at the start.
      def back
        return nil if @index <= 0

        @index -= 1
        current
      end

      # Move the cursor forward one entry and return that URL, or nil at the end.
      def forward
        return nil if @index >= @stack.size - 1

        @index += 1
        current
      end

      def current
        @stack[@index] if @index >= 0
      end

      def entries
        @stack.dup
      end
    end
  end
end
