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
          "cursor" => Property.new(inherited: true, initial: "auto"),
          "z-index" => Property.new(inherited: false, initial: "auto"),
          "position" => Property.new(inherited: false, initial: "static"),
        }.freeze

        COLOR_PROPERTIES = %w[color background-color].freeze

        FONT_WEIGHT_KEYWORDS = {"normal" => "400", "bold" => "700"}.freeze

        # text-decoration-line keywords (text-decoration shorthand picks
        # these out; remaining tokens are style/color and stay unexpanded).
        TEXT_DECORATION_LINES = %w[none underline overline line-through blink].freeze

        BOX_SHORTHANDS = {
          "margin" => "margin-%s",
          "padding" => "padding-%s",
          "inset" => "%s",
        }.freeze

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
          "text-decoration" => %w[text-decoration-line],
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
          else
            [[name, value]]
          end
        end

        # The computed-value transform for one property. `font_size` /
        # `root_font_size` are the element's / root's computed font-size in px
        # (used to resolve em/rem lengths without layout).
        def computed_value(name, value, font_size:, root_font_size:)
          return Color.normalize(value) if COLOR_PROPERTIES.include?(name)
          return FONT_WEIGHT_KEYWORDS.fetch(value.downcase, value) if name == "font-weight"

          resolve_font_relative_length(value, font_size, root_font_size) || value
        end

        # Resolve a bare "<number>em" / "<number>rem" length against the
        # given font sizes. Returns nil when the value isn't such a length
        # (or the needed font size couldn't be resolved to px).
        def resolve_font_relative_length(value, font_size, root_font_size)
          match = value.match(/\A(-?\d+(?:\.\d+)?)(em|rem)\z/i)
          return nil unless match

          base = match[2].downcase == "em" ? font_size : root_font_size
          return nil unless base

          format_px(match[1].to_f * base)
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
          lines = value.split(/\s+/).select { |t| TEXT_DECORATION_LINES.include?(t.downcase) }
          [["text-decoration-line", lines.empty? ? "none" : lines.join(" ")]]
        end
      end
    end
  end
end
