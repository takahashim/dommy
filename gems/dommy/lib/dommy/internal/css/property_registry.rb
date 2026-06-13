# frozen_string_literal: true

require_relative "color"

module Dommy
  module Internal
    module CSS
      # The curated property table driving the cascade: which properties
      # inherit, their initial values, computed-value transforms, and
      # shorthand expansion. Properties outside the table degrade gracefully:
      # their cascaded value is returned as-is (no inheritance, no
      # normalization) rather than raising.
      module PropertyRegistry
        Property = Struct.new(:inherited, :initial, keyword_init: true)

        PROPERTIES = {
          "display" => Property.new(inherited: false, initial: "inline"),
          "visibility" => Property.new(inherited: true, initial: "visible"),
          "opacity" => Property.new(inherited: false, initial: "1"),
          "color" => Property.new(inherited: true, initial: "rgb(0, 0, 0)"),
          "background-color" => Property.new(inherited: false, initial: "rgba(0, 0, 0, 0)"),
          "font-size" => Property.new(inherited: true, initial: "16px"),
          "font-family" => Property.new(inherited: true, initial: "sans-serif"),
          "font-weight" => Property.new(inherited: true, initial: "400"),
          "font-style" => Property.new(inherited: true, initial: "normal"),
          "line-height" => Property.new(inherited: true, initial: "normal"),
          "text-align" => Property.new(inherited: true, initial: "start"),
          "text-decoration-line" => Property.new(inherited: false, initial: "none"),
          "white-space" => Property.new(inherited: true, initial: "normal"),
          "letter-spacing" => Property.new(inherited: true, initial: "normal"),
          "word-spacing" => Property.new(inherited: true, initial: "normal"),
          "cursor" => Property.new(inherited: true, initial: "auto"),
          "direction" => Property.new(inherited: true, initial: "ltr"),
          "text-transform" => Property.new(inherited: true, initial: "none"),
          "text-indent" => Property.new(inherited: true, initial: "0px"),
          "font-variant" => Property.new(inherited: true, initial: "normal"),
          "list-style-type" => Property.new(inherited: true, initial: "disc"),
          "list-style-position" => Property.new(inherited: true, initial: "outside"),
          "list-style-image" => Property.new(inherited: true, initial: "none"),
          "tab-size" => Property.new(inherited: true, initial: "8"),
          "z-index" => Property.new(inherited: false, initial: "auto"),
          "position" => Property.new(inherited: false, initial: "static"),
          # Color longhands of the border/outline/text-decoration shorthands:
          # registered so they normalize to rgb() and resolve currentColor (the
          # initial of each). Width/style longhands stay unregistered (passed
          # through as specified — Dommy applies no style-dependent used-value
          # rule like "width is 0 when style is none").
          "border-top-color" => Property.new(inherited: false, initial: "currentColor"),
          "border-right-color" => Property.new(inherited: false, initial: "currentColor"),
          "border-bottom-color" => Property.new(inherited: false, initial: "currentColor"),
          "border-left-color" => Property.new(inherited: false, initial: "currentColor"),
          "outline-color" => Property.new(inherited: false, initial: "currentColor"),
          "text-decoration-color" => Property.new(inherited: false, initial: "currentColor"),
          "text-decoration-style" => Property.new(inherited: false, initial: "solid"),
          "flex-grow" => Property.new(inherited: false, initial: "0"),
          "flex-shrink" => Property.new(inherited: false, initial: "1"),
          "flex-basis" => Property.new(inherited: false, initial: "auto"),
          "flex-direction" => Property.new(inherited: false, initial: "row"),
          "flex-wrap" => Property.new(inherited: false, initial: "nowrap"),
        }.freeze

        COLOR_PROPERTIES = %w[
          color background-color
          border-top-color border-right-color border-bottom-color border-left-color
          outline-color text-decoration-color
        ].freeze

        FONT_WEIGHT_KEYWORDS = {"normal" => "400", "bold" => "700"}.freeze

        # text-decoration sub-property keyword sets (the shorthand classifies
        # each token as a line, a style, or — failing both — a color).
        TEXT_DECORATION_LINES = %w[none underline overline line-through blink].freeze
        TEXT_DECORATION_STYLES = %w[solid double dotted dashed wavy].freeze

        BORDER_SIDES = %w[top right bottom left].freeze
        BORDER_STYLE_KEYWORDS = %w[none hidden dotted dashed solid double groove ridge inset outset].freeze
        BORDER_WIDTH_KEYWORDS = %w[thin medium thick].freeze

        BOX_SHORTHANDS = {
          "margin" => "margin-%s",
          "padding" => "padding-%s",
          "inset" => "%s",
        }.freeze

        # Per-side longhands of the `border` family, in (width, style, color)
        # order across the four sides — the targets a CSS-wide keyword on
        # `border` expands to.
        BORDER_LONGHANDS = BORDER_SIDES.flat_map do |side|
          %w[width style color].map { |kind| "border-#{side}-#{kind}" }
        end.freeze

        # The longhands each curated shorthand covers — what a CSS-wide
        # keyword (or an invalid var() substitution) applies to when it
        # appears as the shorthand's whole value.
        EXPANSION_TARGETS = {
          "margin" => %w[margin-top margin-right margin-bottom margin-left],
          "padding" => %w[padding-top padding-right padding-bottom padding-left],
          "inset" => %w[top right bottom left],
          "overflow" => %w[overflow-x overflow-y],
          "gap" => %w[row-gap column-gap],
          "background" => %w[background-color],
          "font" => %w[font-style font-weight font-size line-height font-family],
          "text-decoration" => %w[text-decoration-line text-decoration-style text-decoration-color],
          "border" => BORDER_LONGHANDS,
          "border-width" => %w[border-top-width border-right-width border-bottom-width border-left-width],
          "border-style" => %w[border-top-style border-right-style border-bottom-style border-left-style],
          "border-color" => %w[border-top-color border-right-color border-bottom-color border-left-color],
          "border-top" => %w[border-top-width border-top-style border-top-color],
          "border-right" => %w[border-right-width border-right-style border-right-color],
          "border-bottom" => %w[border-bottom-width border-bottom-style border-bottom-color],
          "border-left" => %w[border-left-width border-left-style border-left-color],
          "outline" => %w[outline-width outline-style outline-color],
          "flex" => %w[flex-grow flex-shrink flex-basis],
          "flex-flow" => %w[flex-direction flex-wrap],
          "list-style" => %w[list-style-type list-style-position list-style-image],
          "place-content" => %w[align-content justify-content],
          "place-items" => %w[align-items justify-items],
          "place-self" => %w[align-self justify-self],
        }.freeze

        module_function

        def known?(name) = PROPERTIES.key?(name)

        def expansion_targets(name) = EXPANSION_TARGETS.fetch(name, [name])

        # Custom properties inherit by default (css-variables-1 §2); their
        # initial value is the guaranteed-invalid value (nil here).
        def inherited?(name) = name.start_with?("--") || PROPERTIES[name]&.inherited || false

        def initial(name) = PROPERTIES[name]&.initial

        # Expand a (possibly shorthand) declaration into [[name, value], ...]
        # longhand pairs. Cascade correctness is the point: a later shorthand
        # must reset the longhands it covers (e.g. `background: url(x)` resets
        # background-color to its initial). Shorthands outside this curated
        # set pass through unexpanded (documented divergence).
        def expand(name, value)
          value = value.to_s.strip
          case name
          when "margin", "padding", "inset"
            expand_box(BOX_SHORTHANDS[name], value) || [[name, value]]
          when "overflow"
            expand_overflow(value)
          when "gap"
            expand_gap(value)
          when "background"
            [["background-color", Color.extract(value) || initial("background-color")]]
          when "font"
            expand_font(value) || [[name, value]]
          when "text-decoration"
            expand_text_decoration(value)
          when "border"
            expand_border_all(value)
          when "border-top", "border-right", "border-bottom", "border-left"
            expand_border_side(name.delete_prefix("border-"), value)
          when "border-width", "border-style", "border-color"
            expand_border_box(name.delete_prefix("border-"), value) || [[name, value]]
          when "outline"
            expand_outline(value)
          when "flex"
            expand_flex(value)
          when "flex-flow"
            expand_flex_flow(value)
          when "list-style"
            expand_list_style(value)
          when "place-content", "place-items", "place-self"
            expand_place(name.delete_prefix("place-"), value)
          else
            [[name, value]]
          end
        end

        # px-per-unit for the absolute length units (CSS Values 4: 96px per
        # inch). These need no layout, so a computed value can carry them as px.
        ABSOLUTE_UNIT_PX = {
          "px" => 1.0,
          "pt" => 96.0 / 72,
          "pc" => 16.0,
          "in" => 96.0,
          "cm" => 96.0 / 2.54,
          "mm" => 96.0 / 25.4,
          "q" => 96.0 / 25.4 / 40,
        }.freeze

        LENGTH_PATTERN = /\A(-?\d+(?:\.\d+)?)(px|em|rem|pt|pc|in|cm|mm|q|vw|vh|vmin|vmax)\z/i

        # The computed-value transform for one property. `font_size` /
        # `root_font_size` are the element's / root's computed font-size in px;
        # `viewport_width` / `viewport_height` the viewport in px. Together they
        # let a bare length resolve to px without layout (em/rem/absolute/vw/vh).
        def computed_value(name, value, font_size:, root_font_size:, viewport_width: nil, viewport_height: nil)
          return Color.normalize(value) if COLOR_PROPERTIES.include?(name)
          return FONT_WEIGHT_KEYWORDS.fetch(value.downcase, value) if name == "font-weight"

          resolve_length(value,
            font_size: font_size, root_font_size: root_font_size,
            viewport_width: viewport_width, viewport_height: viewport_height) || value
        end

        # Resolve a bare "<number><unit>" length to px. Handles font-relative
        # (em/rem), absolute (px/pt/pc/in/cm/mm/Q) and viewport (vw/vh/vmin/vmax)
        # units — everything resolvable without layout. Returns nil when the
        # value isn't a single such length (or the needed base is unavailable),
        # so the caller keeps the specified value.
        def resolve_length(value, font_size:, root_font_size:, viewport_width: nil, viewport_height: nil)
          match = value.match(LENGTH_PATTERN)
          return nil unless match

          number = match[1].to_f
          unit = match[2].downcase
          px =
            case unit
            when "em" then font_size && number * font_size
            when "rem" then root_font_size && number * root_font_size
            when "vw" then viewport_width && number * viewport_width / 100.0
            when "vh" then viewport_height && number * viewport_height / 100.0
            when "vmin" then viewport_width && viewport_height && number * [viewport_width, viewport_height].min / 100.0
            when "vmax" then viewport_width && viewport_height && number * [viewport_width, viewport_height].max / 100.0
            else number * ABSOLUTE_UNIT_PX[unit]
            end
          px && format_px(px)
        end

        def format_px(number)
          rounded = number.round(3)
          rounded == rounded.to_i ? "#{rounded.to_i}px" : "#{rounded}px"
        end

        # -- shorthand expansions ------------------------------------------

        # CSS box expansion: 1 value -> all sides, 2 -> v/h, 3 -> t/h/b, 4 ->
        # t/r/b/l. Returns nil for token counts outside 1..4 (or values with
        # nested whitespace we can't split safely).
        def expand_box(pattern, value)
          tokens = value.split(/\s+/)
          return nil unless (1..4).cover?(tokens.size) && tokens.none? { |t| t.include?("(") }

          top, right, bottom, left =
            case tokens.size
            when 1 then [tokens[0]] * 4
            when 2 then [tokens[0], tokens[1], tokens[0], tokens[1]]
            when 3 then [tokens[0], tokens[1], tokens[2], tokens[1]]
            else tokens
            end
          %w[top right bottom left].zip([top, right, bottom, left]).map do |side, v|
            [format(pattern, side), v]
          end
        end

        def expand_overflow(value)
          x, y = value.split(/\s+/)
          [["overflow-x", x], ["overflow-y", y || x]]
        end

        def expand_gap(value)
          row, column = value.split(/\s+/)
          [["row-gap", row], ["column-gap", column || row]]
        end

        # Minimal `font` shorthand: [style] [weight] <size>[/<line-height>]
        # <family...>. Omitted sub-properties reset to their initial value
        # (shorthand semantics). Returns nil when no size token is found
        # (e.g. system font keywords) so the caller passes it through.
        def expand_font(value)
          tokens = value.split(/\s+/)
          size_index = tokens.index { |t| t.match?(%r{\A\d+(?:\.\d+)?(px|em|rem|%)(/|\z)}i) }
          return nil unless size_index

          style = "normal"
          weight = "400"
          tokens[0...size_index].each do |token|
            case token.downcase
            when "italic", "oblique" then style = token.downcase
            when "bold", /\A[1-9]00\z/ then weight = FONT_WEIGHT_KEYWORDS.fetch(token.downcase, token)
            end
          end

          size, line_height = tokens[size_index].split("/", 2)
          family = tokens[(size_index + 1)..].join(" ")

          pairs = [
            ["font-style", style],
            ["font-weight", weight],
            ["font-size", size],
            ["line-height", line_height || "normal"],
          ]
          pairs << ["font-family", family] unless family.empty?
          pairs
        end

        def expand_text_decoration(value)
          lines = []
          style = nil
          color = nil
          split_tokens(value).each do |token|
            low = token.downcase
            if TEXT_DECORATION_LINES.include?(low)
              lines << token
            elsif TEXT_DECORATION_STYLES.include?(low)
              style = token
            else
              color ||= token
            end
          end
          [["text-decoration-line", lines.empty? ? "none" : lines.join(" ")],
           ["text-decoration-style", style || "solid"],
           ["text-decoration-color", color || "currentColor"]]
        end

        # Whitespace split that keeps parenthesized groups intact, so a color
        # `rgb(0, 0, 0)` or an `url(...)` stays one token.
        def split_tokens(value)
          tokens = []
          current = +""
          depth = 0
          value.each_char do |char|
            if char == "("
              depth += 1
              current << char
            elsif char == ")"
              depth -= 1 if depth.positive?
              current << char
            elsif char.match?(/\s/) && depth.zero?
              tokens << current unless current.empty?
              current = +""
            else
              current << char
            end
          end
          tokens << current unless current.empty?
          tokens
        end

        # 1 value -> all sides, 2 -> v/h, 3 -> t/h/b, 4 -> t/r/b/l.
        def box_values(tokens)
          case tokens.size
          when 1 then [tokens[0]] * 4
          when 2 then [tokens[0], tokens[1], tokens[0], tokens[1]]
          when 3 then [tokens[0], tokens[1], tokens[2], tokens[1]]
          else tokens[0, 4]
          end
        end

        # Classify the tokens of a `border`/`border-<side>`/`outline` value into
        # {width:, style:, color:} (order-independent, omitted parts nil).
        def parse_border_shorthand(value)
          parts = {width: nil, style: nil, color: nil}
          split_tokens(value).each do |token|
            low = token.downcase
            if parts[:style].nil? && BORDER_STYLE_KEYWORDS.include?(low)
              parts[:style] = token
            elsif parts[:width].nil? && border_width_token?(low)
              parts[:width] = token
            else
              parts[:color] ||= token
            end
          end
          parts
        end

        def border_width_token?(low)
          BORDER_WIDTH_KEYWORDS.include?(low) || low.match?(/\A[.\-\d]/)
        end

        # Omitted border sub-properties reset to their initial (shorthand
        # semantics): width medium, style none, color currentColor.
        def border_triple(prefix, parts)
          [["#{prefix}-width", parts[:width] || "medium"],
           ["#{prefix}-style", parts[:style] || "none"],
           ["#{prefix}-color", parts[:color] || "currentColor"]]
        end

        def expand_border_all(value)
          parts = parse_border_shorthand(value)
          BORDER_SIDES.flat_map { |side| border_triple("border-#{side}", parts) }
        end

        def expand_border_side(side, value)
          border_triple("border-#{side}", parse_border_shorthand(value))
        end

        # `border-width|style|color: <box>` — one kind across the four sides.
        def expand_border_box(kind, value)
          tokens = split_tokens(value)
          return nil unless (1..4).cover?(tokens.size)

          BORDER_SIDES.zip(box_values(tokens)).map { |side, v| ["border-#{side}-#{kind}", v] }
        end

        def expand_outline(value)
          parts = parse_border_shorthand(value)
          [["outline-width", parts[:width] || "medium"],
           ["outline-style", parts[:style] || "none"],
           ["outline-color", parts[:color] || "currentColor"]]
        end

        # `flex` per css-flexbox-1 §7.1.1: none -> 0 0 auto, auto -> 1 1 auto,
        # a bare number -> grow 1 0%, etc. Omitted parts take the shorthand's
        # reset values, not the longhand initials.
        def expand_flex(value)
          tokens = split_tokens(value)
          grow, shrink, basis =
            case tokens.size
            when 1 then flex_one(tokens[0])
            when 2 then flex_two(tokens[0], tokens[1])
            else tokens[0, 3]
            end
          [["flex-grow", grow], ["flex-shrink", shrink], ["flex-basis", basis]]
        end

        def flex_one(token)
          case token.downcase
          when "none" then ["0", "0", "auto"]
          when "auto" then ["1", "1", "auto"]
          when "initial" then ["0", "1", "auto"]
          else number?(token) ? [token, "1", "0%"] : ["1", "1", token]
          end
        end

        def flex_two(first, second)
          number?(second) ? [first, second, "0%"] : [first, "1", second]
        end

        def number?(token) = token.match?(/\A-?\d+(?:\.\d+)?\z/)

        def expand_flex_flow(value)
          direction = nil
          wrap = nil
          split_tokens(value).each do |token|
            low = token.downcase
            if %w[row row-reverse column column-reverse].include?(low)
              direction = token
            elsif %w[nowrap wrap wrap-reverse].include?(low)
              wrap = token
            end
          end
          [["flex-direction", direction || "row"], ["flex-wrap", wrap || "nowrap"]]
        end

        # `list-style: <type> || <position> || <image>` (any order). A `none`
        # sets both type and image to none (css-lists-3).
        def expand_list_style(value)
          type = position = image = nil
          none = false
          split_tokens(value).each do |token|
            low = token.downcase
            if %w[inside outside].include?(low)
              position = token
            elsif low.start_with?("url(")
              image = token
            elsif low == "none"
              none = true
            else
              type = token
            end
          end
          type ||= "none" if none
          image ||= "none" if none
          [["list-style-type", type || "disc"],
           ["list-style-position", position || "outside"],
           ["list-style-image", image || "none"]]
        end

        # place-content/items/self: `<align> [<justify>]`; a single value
        # applies to both. (Multi-keyword alignment values like `safe center`
        # are not split — a documented simplification.)
        def expand_place(suffix, value)
          tokens = split_tokens(value)
          [["align-#{suffix}", tokens[0]], ["justify-#{suffix}", tokens[1] || tokens[0]]]
        end
      end
    end
  end
end
