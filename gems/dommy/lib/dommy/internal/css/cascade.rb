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
        def computed_style(element, pseudo_element: nil)
          document = element.owner_document
          return {}.freeze unless document
          # CSSOM: an element outside the flat tree has no computed style —
          # browsers return empty strings for every property.
          return {}.freeze if element.respond_to?(:is_connected?) && !element.is_connected?

          cache = style_cache(document)
          if pseudo_element
            cache[:pseudo_computed] ||= {}
            pseudo_cache = (cache[:pseudo_computed][pseudo_name(pseudo_element)] ||= {}.compare_by_identity)
            pseudo_cache[element] ||= compute(element, document, pseudo_element: pseudo_element).freeze
          else
            cache[:computed][element] ||= compute(element, document).freeze
          end
        end

        # Cheap per-generation gate used by visibility checks: does the
        # document carry any author CSS at all? When it doesn't (and for
        # makiri-less installs), the HTML-level fast path is already exact
        # and no RuleIndex needs building.
        def author_css?(document)
          return false unless document && Parser.available?

          cache = style_cache(document)
          cache[:author_css] = document_has_author_css?(document) if cache[:author_css].nil?
          cache[:author_css]
        end

        # Any <style>, or a <link rel=stylesheet> a host has filled in (an
        # unfilled link contributes nothing, so it stays off the slow path).
        def document_has_author_css?(document)
          return true unless document.query_selector("style").nil?

          document.query_selector_all("link").any? do |link|
            link.respond_to?(:__internal_stylesheet_for_cascade__) && link.__internal_stylesheet_for_cascade__
          end
        end

        def style_cache(document)
          cache = document.__css_style_cache__
          unless cache && cache[:generation] == document.style_generation
            cache = {
              generation: document.style_generation,
              computed: {}.compare_by_identity,
              pseudo_computed: {},
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

        def compute(element, document, pseudo_element: nil)
          index = index_for(document)

          parent = pseudo_element ? nil : element.parent_element
          parent_styles = if pseudo_element
            computed_style(element)
          else
            parent ? computed_style(parent) : nil
          end

          # Two passes (css-variables-1 §3): the custom properties resolve
          # first, then every other declaration substitutes var() BEFORE
          # shorthand expansion and wide-keyword interpretation — so
          # `background: var(--c)` expands the substituted value, not the
          # literal var() text.
          custom_winners, custom_ua = collect_winners(element, index, pseudo_element: pseudo_element, custom_only: true)
          custom = resolve_custom_properties(custom_winners, custom_ua, parent_styles)

          winners, ua_winners = collect_winners(element, index, pseudo_element: pseudo_element, custom: custom)

          fetch = lambda do |name|
            resolve_cascaded(name, winners, ua_winners, parent_styles)
          end

          root = document.document_element
          root_px = if root.nil? || element.equal?(root)
            ROOT_FONT_SIZE_PX
          else
            px_of(computed_style(root)["font-size"]) || ROOT_FONT_SIZE_PX
          end
          vw, vh = viewport(document)

          result = {}
          result["font-size"] = compute_font_size(fetch.call("font-size"), parent_styles, root_px, vw, vh)
          own_px = px_of(result["font-size"])

          PropertyRegistry::PROPERTIES.each_key do |name|
            next if name == "font-size"

            value = fetch.call(name)
            value ||= if PropertyRegistry.inherited?(name) && parent_styles
              parent_styles[name]
            else
              PropertyRegistry.initial(name)
            end
            # `color: currentColor` means "inherit the color" (there is no
            # other color to point at); resolve it before normalization so the
            # value other properties' currentColor resolves against is real.
            if name == "color" && value.to_s.casecmp("currentcolor").zero?
              value = parent_styles ? parent_styles["color"] : PropertyRegistry.initial("color")
            end
            result[name] = PropertyRegistry.computed_value(
              name, value.to_s, font_size: own_px, root_font_size: root_px,
              viewport_width: vw, viewport_height: vh
            )
          end

          # Unregistered properties degrade to their cascaded value as-is
          # (no inheritance, no normalization).
          winners.each_key do |name|
            next if PropertyRegistry.known?(name) || name.start_with?("--") || result.key?(name)

            value = fetch.call(name)
            result[name] = value if value
          end

          # currentColor resolves to the element's own computed color (CSSOM
          # resolved value), in every other property that carries it.
          resolve_current_color!(result)

          # Computed custom properties are part of the computed style: the
          # children inherit them from here, and getPropertyValue("--x")
          # reads them.
          result.merge!(custom)

          result
        end

        # Replace the `currentColor` keyword — whole-value or embedded (e.g.
        # `border: 1px solid currentColor`) — with the computed `color`, for
        # every property except `color` itself (already resolved) and custom
        # properties (var() substitutes those before this point).
        def resolve_current_color!(result)
          own = result["color"]
          return unless own

          result.each do |name, value|
            next if name == "color" || name.start_with?("--")
            next unless value.is_a?(String) && value.match?(/\bcurrentcolor\b/i)

            result[name] = value.gsub(/\bcurrentcolor\b/i, own)
          end
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
        # `custom_only: true` collects just the custom-property declarations
        # (pass 1); the main pass receives the resolved `custom:` set so
        # var() substitutes before expansion.
        def collect_winners(element, index, pseudo_element: nil, custom: nil, custom_only: false)
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
            if name.start_with?("--")
              consider.call(name, value, rank, origin) if custom_only
              next
            end
            next if custom_only

            expand_declaration(name, value, custom).each do |(expanded_name, expanded_value)|
              consider.call(expanded_name, expanded_value, rank, origin)
            end
          end

          [winners, ua_winners]
        end

        # Every declaration that cascades onto the element, with its
        # precedence rank: matched rules first, then the style attribute
        # (which doesn't apply to pseudo-elements).
        def each_declaration(element, index, pseudo_element)
          index.matches_for(element, pseudo_element).each do |match|
            match.declarations.each_with_index do |decl, position|
              rank = precedence(match.origin, decl.important, match.specificity, match.order, position)
              yield decl.name, decl.value, rank, match.origin
            end
          end
          return if pseudo_element

          inline_declarations(element).each_with_index do |(name, value, important), position|
            rank = precedence(:inline, important, [0, 0, 0], INLINE_ORDER, position)
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

            important = !value.sub!(/\s*!\s*important\s*\z/i, "").nil?
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

        # font-size is computed first: em/%/rem/absolute/viewport units resolve
        # against the parent / root computed font-size and the viewport, none of
        # which needs layout. (em and % are relative to the *parent* font-size.)
        # Keywords and unhandled values pass through as specified.
        def compute_font_size(specified, parent_styles, root_px, viewport_width, viewport_height)
          inherited = parent_styles ? parent_styles["font-size"] : PropertyRegistry.initial("font-size")
          return inherited if specified.nil?

          parent_px = px_of(inherited) || ROOT_FONT_SIZE_PX
          if (match = specified.match(/\A(-?\d+(?:\.\d+)?)%\z/i))
            return PropertyRegistry.format_px(match[1].to_f / 100.0 * parent_px)
          end

          # em inside a font-size calc is relative to the parent font-size.
          ctx = {font_size: parent_px, root_font_size: root_px,
                 viewport_width: viewport_width, viewport_height: viewport_height}
          PropertyRegistry.evaluate_calc(specified, **ctx) ||
            PropertyRegistry.resolve_length(specified, **ctx) || specified
        end

        # The viewport size in px for resolving vw/vh, from the document's
        # window media environment. nil when the document has no window
        # (fragments, DOMParser output) — vw/vh then stay as specified.
        def viewport(document)
          view = document.respond_to?(:default_view) ? document.default_view : nil
          env = view&.media_environment
          env ? [env.viewport_width, env.viewport_height] : [nil, nil]
        end

        def px_of(value)
          match = value.to_s.match(/\A(-?\d+(?:\.\d+)?)px\z/i)
          match && match[1].to_f
        end

        def pseudo_name(pseudo_element)
          pseudo_element.to_s.delete_prefix("::").delete_prefix(":")
        end
      end
    end
  end
end
