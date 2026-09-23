# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # Everything the cascade remembers about one document for one style
      # generation: the rule index, the per-element computed styles, the counter
      # map and whether the document has author CSS at all.
      #
      # It hangs off the Document because that is what the generation belongs
      # to, and it is an object rather than the bare Hash it used to be because
      # both sides reach for it — Cascade to fill it, Document to ask the index
      # whether a mutation matters. A symbol-keyed Hash left that shared shape
      # written down nowhere.
      #
      # Nothing here is invalidated piecemeal. A generation bump throws the
      # whole cache away, which is what makes the memos safe to hold.
      class StyleCache
        attr_reader :generation
        attr_accessor :index, :counters, :author_css

        def initialize(generation)
          @generation = generation
          @computed = {}.compare_by_identity
          @pseudo_computed = {}
        end

        def current?(generation) = @generation == generation

        # The element's computed style, computing and freezing it on first ask.
        def computed(element)
          @computed[element] ||= yield.freeze
        end

        # The same, per pseudo-element name.
        def pseudo_computed(name, element)
          memo = (@pseudo_computed[name] ||= {}.compare_by_identity)
          memo[element] ||= yield.freeze
        end
      end
    end
  end
end
