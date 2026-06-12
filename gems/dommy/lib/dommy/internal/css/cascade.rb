# frozen_string_literal: true

require_relative "parser"
require_relative "property_registry"
require_relative "custom_properties"
require_relative "rule_index"
require_relative "computed_style_declaration"

module Dommy
  module Internal
    module CSS
      # The cascade core (css-cascade.md P1): resolves an element's computed
      # style from the UA sheet, the document's <style> sheets, and its
      # style attribute. Per-document state (RuleIndex + per-element memo)
      # is cached against Document#style_generation and rebuilt wholesale
      # when any mutation bumps it.
      #
      # Precedence, high to low: UA !important > author !important (the
      # style attribute's !important on top) > style attribute > author
      # normal (specificity, then source order) > UA normal.
      module Cascade
        # Order slot for style-attribute declarations (they have their own
        # precedence levels; the order only breaks ties among themselves).
        INLINE_ORDER = 1 << 30

        WIDE_KEYWORDS = %w[initial inherit unset revert].freeze

        ROOT_FONT_SIZE_PX = 16.0

        module_function

        # The computed style of `element` as a frozen Hash of
        # "property" => "value" strings. Raises Parser::Unavailable when the
        # makiri-backed CSS parser is missing.
        def computed_style(element)
          document = element.owner_document
          return {}.freeze unless document

          cache = style_cache(document)
          cache[:computed][element] ||= compute(element, document).freeze
        end

        # Cheap per-generation gate used by visibility checks: does the
        # document carry any author CSS at all? When it doesn't (and for
        # makiri-less installs), the HTML-level fast path is already exact
        # and no RuleIndex needs building.
        def author_css?(document)
          return false unless document && Parser.available?

          cache = style_cache(document)
          cache[:author_css] = !document.query_selector("style").nil? if cache[:author_css].nil?
          cache[:author_css]
        end

        def style_cache(document)
          cache = document.__css_style_cache__
          unless cache && cache[:generation] == document.style_generation
            cache = {
              generation: document.style_generation,
              computed: {}.compare_by_identity,
            }
            document.__css_style_cache__ = cache
          end
          cache
        end

        # The RuleIndex is built lazily so author_css? (and sheetless
        # documents in general) never pay for UA-sheet selector queries.
        def index_for(document)
          style_cache(document)[:index] ||= RuleIndex.build(document)
        end

        def compute(element, document)
          winners, ua_winners = collect_winners(element, index_for(document))

          parent = element.parent_element
          parent_styles = parent ? computed_style(parent) : nil

          custom = resolve_custom_properties(winners, ua_winners, parent_styles)

          # The cascaded value with var() substituted; nil both for "no
          # declaration" and for "invalid at computed-value time", which the
          # caller's inherit/initial default fill handles (= unset, per
          # css-variables-1 §3).
          fetch = lambda do |name|
            value = resolve_cascaded(name, winners, ua_winners, parent_styles)
            next value unless value&.include?("var(")

            substituted = CustomProperties.substitute(value, ->(n) { custom[n] })
            substituted.is_a?(String) && !substituted.strip.empty? ? substituted.strip : nil
          end

          root = document.document_element
          root_px = if root.nil? || element.equal?(root)
            ROOT_FONT_SIZE_PX
          else
            px_of(computed_style(root)["font-size"]) || ROOT_FONT_SIZE_PX
          end

          result = {}
          result["font-size"] = compute_font_size(fetch.call("font-size"), parent_styles, root_px)
          own_px = px_of(result["font-size"])

          PropertyRegistry::PROPERTIES.each_key do |name|
            next if name == "font-size"

            value = fetch.call(name)
            value ||= if PropertyRegistry.inherited?(name) && parent_styles
              parent_styles[name]
            else
              PropertyRegistry.initial(name)
            end
            result[name] = PropertyRegistry.computed_value(
              name, value.to_s, font_size: own_px, root_font_size: root_px
            )
          end

          # Unregistered properties degrade to their cascaded value as-is
          # (no inheritance, no normalization).
          winners.each_key do |name|
            next if PropertyRegistry.known?(name) || name.start_with?("--") || result.key?(name)

            value = fetch.call(name)
            result[name] = value if value
          end

          # Computed custom properties are part of the computed style: the
          # children inherit them from here, and getPropertyValue("--x")
          # reads them.
          result.merge!(custom)

          result
        end

        # The element's computed custom property set: the parent's (custom
        # properties inherit), overlaid with this element's cascaded
        # declarations, then var()-resolved with cycle detection. An
        # explicit `initial` (or an unresolvable value) removes the entry —
        # the guaranteed-invalid value.
        def resolve_custom_properties(winners, ua_winners, parent_styles)
          merged = parent_styles ? parent_styles.select { |key, _| key.start_with?("--") } : {}
          winners.each_key do |name|
            next unless name.start_with?("--")

            value = resolve_cascaded(name, winners, ua_winners, parent_styles)
            value.nil? ? merged.delete(name) : merged[name] = value
          end
          CustomProperties.resolve_all(merged)
        end

        # Gather the winning declaration per property — and separately the
        # winning UA declaration, which is what `revert` rolls back to.
        def collect_winners(element, index)
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

          index.matches_for(element).each do |match|
            match.declarations.each_with_index do |decl, position|
              rank = precedence(match.origin, decl.important, match.specificity, match.order, position)
              PropertyRegistry.expand(decl.name, decl.value).each do |(name, value)|
                consider.call(name, value, rank, match.origin)
              end
            end
          end

          inline_declarations(element).each_with_index do |(name, value, important), position|
            rank = precedence(:inline, important, [0, 0, 0], INLINE_ORDER, position)
            PropertyRegistry.expand(name, value).each do |(n, v)|
              consider.call(n, v, rank, :inline)
            end
          end

          [winners, ua_winners]
        end

        # Comparable precedence tuple: importance level, specificity (A,B,C),
        # rule order, declaration position. Later/higher wins on <=>. The
        # style attribute gets its own levels (above same-importance author
        # rules) because it outranks any selector's specificity.
        def precedence(origin, important, specificity, order, position)
          level = if important
            {ua: 5, inline: 4, author: 3}.fetch(origin)
          else
            {inline: 2, author: 1, ua: 0}.fetch(origin)
          end
          [level, specificity[0], specificity[1], specificity[2], order, position]
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

            important = !value.sub!(/\s*!important\s*\z/i, "").nil?
            [name, value, important]
          end
        end

        # Resolve a property's cascaded value, interpreting the CSS-wide
        # keywords. Returns nil when there is no declaration (or the keyword
        # resolves to "fall back to the inherit/initial default fill").
        def resolve_cascaded(name, winners, ua_winners, parent_styles)
          entry = winners[name]
          return nil unless entry

          value = entry[:value].to_s
          if value.casecmp("revert").zero?
            # Roll back the author/inline win to the UA winner; a UA-level
            # revert (or no UA declaration) behaves as unset.
            entry = entry[:origin] == :ua ? nil : ua_winners[name]
            return resolve_wide_keyword(name, "unset", parent_styles) unless entry

            value = entry[:value].to_s
          end

          if WIDE_KEYWORDS.include?(value.downcase)
            resolve_wide_keyword(name, value.downcase, parent_styles)
          else
            value
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

        # font-size is computed first: em/rem/% resolve against the parent /
        # root computed font-size, which needs no layout. Keywords and other
        # units pass through as specified.
        def compute_font_size(specified, parent_styles, root_px)
          inherited = parent_styles ? parent_styles["font-size"] : PropertyRegistry.initial("font-size")
          return inherited if specified.nil?

          parent_px = px_of(inherited) || ROOT_FONT_SIZE_PX
          case specified
          when /\A(-?\d+(?:\.\d+)?)px\z/i then PropertyRegistry.format_px(Regexp.last_match(1).to_f)
          when /\A(-?\d+(?:\.\d+)?)em\z/i then PropertyRegistry.format_px(Regexp.last_match(1).to_f * parent_px)
          when /\A(-?\d+(?:\.\d+)?)rem\z/i then PropertyRegistry.format_px(Regexp.last_match(1).to_f * root_px)
          when /\A(-?\d+(?:\.\d+)?)%\z/i then PropertyRegistry.format_px(Regexp.last_match(1).to_f / 100.0 * parent_px)
          else specified
          end
        end

        def px_of(value)
          match = value.to_s.match(/\A(-?\d+(?:\.\d+)?)px\z/i)
          match && match[1].to_f
        end
      end
    end
  end
end
