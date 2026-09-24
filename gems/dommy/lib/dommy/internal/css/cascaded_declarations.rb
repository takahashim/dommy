# frozen_string_literal: true

require_relative "property_registry"
require_relative "custom_properties"
require_relative "ua_stylesheet"

module Dommy
  module Internal
    module CSS
      # The cascade's first half: of every declaration that reaches an element,
      # which one wins for each property.
      #
      # Ranking is the whole job. Each declaration gets a comparable precedence
      # tuple — importance, cascade layer, specificity, @scope proximity, source
      # order, position in its block — and the highest tuple per property wins.
      # What that winner then computes to belongs to ComputedStyleBuilder.
      module CascadedDeclarations
        # Order slot for style-attribute declarations (they have their own
        # precedence levels; the order only breaks ties among themselves).
        INLINE_ORDER = 1 << 30

        WIDE_KEYWORDS = %w[initial inherit unset revert].freeze

        # The winners, and separately the winning UA declaration per property,
        # which is what `revert` rolls back to.
        Winners = Struct.new(:by_property, :ua) do
          def each_property(&block) = by_property.each_key(&block)

          # The cascaded value of `name` with the CSS-wide keywords interpreted,
          # or nil when nothing declared it (or the keyword resolves to "fall
          # back to the inherit/initial default fill").
          def value_for(name, parent_styles)
            entry = by_property[name]
            return nil unless entry

            value = entry[:value].to_s
            if value.casecmp("revert").zero?
              # Roll back the author/inline win to the UA winner; a UA-level
              # revert (or no UA declaration) behaves as unset.
              entry = entry[:origin] == :ua ? nil : ua[name]
              return CascadedDeclarations.resolve_wide_keyword(name, "unset", parent_styles) unless entry

              value = entry[:value].to_s
            end

            if WIDE_KEYWORDS.include?(value.downcase)
              CascadedDeclarations.resolve_wide_keyword(name, value.downcase, parent_styles)
            else
              value
            end
          end
        end

        module_function

        # Pass 1 (css-variables-1 §3): the custom-property declarations alone,
        # which have to resolve among themselves before anything else can
        # substitute var().
        def collect_custom(element, index, pseudo_element: nil)
          collect(element, index, pseudo_element) do |name, value, rank, origin, consider|
            consider.call(name, value, rank, origin) if name.start_with?("--")
          end
        end

        # Pass 2: every other declaration, with var() substituted against the
        # resolved `custom` set BEFORE shorthand expansion — so `background:
        # var(--c)` expands the substituted value, not the literal var() text.
        def collect_longhands(element, index, pseudo_element: nil, custom: nil)
          collect(element, index, pseudo_element) do |name, value, rank, origin, consider|
            next if name.start_with?("--")

            expand_declaration(name, value, custom).each do |(expanded_name, expanded_value)|
              consider.call(expanded_name, expanded_value, rank, origin)
            end
          end
        end

        # The ranking machinery both passes share: walk the declarations, hand
        # each to `filter` along with the `consider` that keeps the best one.
        def collect(element, index, pseudo_element)
          winners = {}
          ua_winners = {}

          consider = lambda do |name, value, rank, origin|
            entry = {value: value, rank: rank, origin: origin}
            if origin == :ua && (!(current = ua_winners[name]) || (rank <=> current[:rank]).positive?)
              ua_winners[name] = entry
            end
            if !(current = winners[name]) || (rank <=> current[:rank]).positive?
              winners[name] = entry
            end
          end

          each_declaration(element, index, pseudo_element) do |name, value, rank, origin|
            yield name, value, rank, origin, consider
          end

          Winners.new(winners, ua_winners)
        end

        # Every declaration that cascades onto the element, with its
        # precedence rank: matched rules first, then the UA rules evaluated per
        # element and the style attribute (neither applies to pseudo-elements).
        def each_declaration(element, index, pseudo_element)
          layer_count = index.layer_count
          index.matches_for(element, pseudo_element).each do |match|
            layer_index = index.layer_index_of(match.layer)
            match.declarations.each_with_index do |decl, position|
              rank = precedence(match.origin, decl.important, match.specificity, match.order, position,
                layer_index, match.proximity)
              yield decl.name, decl.value, rank, match.origin
            end
          end
          return if pseudo_element

          UAStylesheet.element_declarations(element).each_with_index do |(name, value, specificity), position|
            rank = precedence(:ua, false, specificity, 0, position, layer_count, nil)
            yield name, value, rank, :ua
          end

          # The style attribute is unlayered (the implicit final layer, index
          # layer_count) and unscoped (nil proximity).
          inline_declarations(element).each_with_index do |(name, value, important), position|
            rank = precedence(:inline, important, [0, 0, 0], INLINE_ORDER, position, layer_count, nil)
            yield name, value, rank, :inline
          end
        end

        # The computed-value-time part of one declaration: substitute var()
        # (an invalid substitution makes the declaration's longhands behave
        # as unset — css-variables-1 §3), interpret a CSS-wide keyword on a
        # shorthand as applying to every longhand, then expand.
        def expand_declaration(name, value, custom)
          value = value.to_s
          if custom && CustomProperties.contains_var?(value)
            substituted = CustomProperties.substitute(value, ->(n) { custom[n] })
            if substituted.is_a?(String) && !substituted.strip.empty?
              value = substituted.strip
            else
              return PropertyRegistry.expansion_targets(name).map { |target| [target, "unset"] }
            end
          end
          if WIDE_KEYWORDS.include?(value.downcase)
            return PropertyRegistry.expansion_targets(name).map { |target| [target, value] }
          end

          PropertyRegistry.expand(name, value)
        end

        # Comparable precedence tuple: importance level, cascade-layer rank,
        # specificity (A,B,C), rule order, declaration position. Later/higher
        # wins on <=>. The style attribute gets its own levels (above
        # same-importance author rules) because it outranks any selector's
        # specificity. The layer rank sits between origin and specificity, per
        # the cascade sort order.
        def precedence(origin, important, specificity, order, position, layer_index, proximity)
          level = if important
            {ua: 5, inline: 4, author: 3}.fetch(origin)
          else
            {inline: 2, author: 1, ua: 0}.fetch(origin)
          end
          [level, layer_rank(important, layer_index),
           specificity[0], specificity[1], specificity[2],
           proximity_rank(proximity), order, position]
        end

        # The @scope contribution to precedence, sitting between specificity and
        # source order. A scoped declaration's proximity is its generation count
        # to the scoping root (0 = the root itself); the nearer scope wins, so it
        # is negated. An unscoped declaration (nil) has proximity infinity, so a
        # scoped declaration of equal specificity always beats it.
        def proximity_rank(proximity)
          proximity ? -proximity : -Float::INFINITY
        end

        # The cascade-layer contribution to a declaration's precedence.
        # `layer_index` is the layer's 0-based order, or the layer count for the
        # implicit final layer that holds unlayered styles (callers pass that for
        # unlayered declarations). For normal declarations a later layer wins, so
        # the index is used directly and the unlayered final layer (highest
        # index) beats every explicit layer. For important declarations the order
        # reverses — an earlier layer wins, and unlayered important is lowest —
        # so the index is negated.
        def layer_rank(important, layer_index)
          important ? -layer_index : layer_index
        end

        # The element's style attribute as [name, value, important] triples.
        # (StyleDeclaration stores the same data but keeps it private; the
        # attribute string is the canonical source either way.)
        def inline_declarations(element)
          return [] unless element.respond_to?(:get_attribute)

          text = element.get_attribute("style").to_s
          return [] if text.empty?

          text.split(";").filter_map do |chunk|
            name, value = chunk.split(":", 2)
            next unless name && value

            name = name.strip
            # Property names are ASCII case-insensitive — except custom
            # properties, which are case-sensitive (css-variables-1 §2).
            name = name.downcase unless name.start_with?("--")
            value = value.strip
            next if name.empty? || value.empty?

            important = !value.sub!(/\s*!\s*important\s*\z/i, "").nil?
            [name, value, important]
          end
        end

        def resolve_wide_keyword(name, keyword, parent_styles)
          keyword = PropertyRegistry.inherited?(name) ? "inherit" : "initial" if %w[unset revert].include?(keyword)
          case keyword
          when "inherit"
            (parent_styles && parent_styles[name]) || PropertyRegistry.initial(name)
          when "initial"
            PropertyRegistry.initial(name)
          end
        end
      end
    end
  end
end
