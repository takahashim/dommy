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
      # whole cache away, which is what makes the memos safe to hold. The one
      # thing handed on is the last rule index built, for the next build to
      # reuse when its inputs have not changed (RuleIndex.build decides).
      class StyleCache
        attr_reader :generation, :previous_index
        attr_accessor :index, :counters, :author_css

        # The document's cache for its current style generation, replacing a
        # stale one.
        def self.for(document)
          cache = document.__internal_css_style_cache__
          unless cache&.current?(document.style_generation)
            cache = new(document.style_generation, previous_index: cache&.index || cache&.previous_index)
            document.__internal_css_style_cache__ = cache
          end
          cache
        end

        def initialize(generation, previous_index: nil)
          @generation = generation
          @previous_index = previous_index
          @computed = {}.compare_by_identity
          @pseudo_computed = {}
          @directions = {}.compare_by_identity
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

        # The element's directionality (Directionality.direction_of), which
        # the cascade reads for every element's `direction`.
        def direction(element)
          @directions[element] ||= yield
        end
      end
    end
  end
end
