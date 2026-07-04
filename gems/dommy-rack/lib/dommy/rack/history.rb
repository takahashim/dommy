# frozen_string_literal: true

module Dommy
  module Rack
    # Browser-tab-style navigation history: ONE ordered stack covering both
    # full-document navigations and same-document (pushState) entries, like a
    # real tab's joint history. Each entry remembers which window it belongs
    # to and that window's own history index, so Session#back / #forward can
    # decide between a popstate traversal (same live document — Turbo Drive's
    # restoration path) and a full re-request (document boundary).
    class History
      # `window` / `windex` tie the entry to a page and its window.history
      # cursor position; Session#back / #forward traverse in-page (popstate)
      # exactly when the target entry's window IS the live current window.
      Entry = Struct.new(:url, :window, :windex)

      def initialize
        @stack = []
        @index = -1
      end

      def push(url, window: nil, windex: nil)
        kept = @index >= 0 ? @stack[0..@index] : []
        @stack = kept + [Entry.new(url, window, windex)]
        @index = @stack.size - 1
        url
      end

      # Move the cursor back/forward one entry and return that Entry, or nil
      # at the edge (Session picks the traversal mechanism from it).
      def back
        return nil if @index <= 0

        @index -= 1
        current_entry
      end

      def forward
        return nil if @index >= @stack.size - 1

        @index += 1
        current_entry
      end

      # replaceState: the current entry's URL changes in place.
      def replace_current_url(url)
        current_entry&.url = url
        url
      end

      # Re-bind the current entry to a fresh window (a revisit re-loaded the
      # URL into a new document), so later same-document sync matches it.
      def rebind_current(window:, windex:)
        entry = current_entry
        return unless entry

        entry.window = window
        entry.windex = windex
      end

      # Mirror a traversal the page itself performed (JS history.back()):
      # move the cursor to the entry recorded for (window, windex). No-op
      # when unknown (e.g. an entry created before sync was installed).
      def sync_to(window, windex)
        i = @stack.index { |e| e.window.equal?(window) && e.windex == windex }
        @index = i if i
        current_entry
      end

      def current_entry
        @stack[@index] if @index >= 0
      end

      # URL-shaped views, kept for compatibility with existing callers.
      def current = current_entry&.url

      def entries
        @stack.map(&:url)
      end
    end
  end
end
