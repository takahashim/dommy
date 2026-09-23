# frozen_string_literal: true

module Dommy
  module Internal
    # Flattening rendered text the way an accessibility name is flattened:
    # ASCII whitespace runs collapse to one space and the ends are trimmed.
    #
    # One rule, stated once, because three places need it — the accessible name,
    # the accessibility tree's text nodes, and the DOM summary — and a name that
    # differed from the tree's text by a run of spaces would be a bug nobody
    # would look for here.
    module TextFlattening
      module_function

      def squish(text)
        text.to_s.gsub(/\s+/, " ").strip
      end
    end
  end
end
