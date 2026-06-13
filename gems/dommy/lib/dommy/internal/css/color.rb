# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # Normalizes CSS color values into the serialization browsers use for
      # `getComputedStyle` — `rgb(r, g, b)` / `rgba(r, g, b, a)`.
      #
      # Supported inputs: the 148 CSS Color Module Level 4 named colors,
      # `transparent`, `#rgb` / `#rgba` / `#rrggbb` / `#rrggbbaa` hex
      # notations, and `rgb()` / `rgba()` functional notation. Anything else
      # (hsl(), var(), …) is passed through unchanged.
      module Color
        module_function

        # CSS Color Module Level 4 named colors (148 keywords) => [r, g, b].
        NAMED = {
          "aliceblue" => [240, 248, 255],
          "antiquewhite" => [250, 235, 215],
          "aqua" => [0, 255, 255],
          "aquamarine" => [127, 255, 212],
          "azure" => [240, 255, 255],
          "beige" => [245, 245, 220],
          "bisque" => [255, 228, 196],
          "black" => [0, 0, 0],
          "blanchedalmond" => [255, 235, 205],
          "blue" => [0, 0, 255],
          "blueviolet" => [138, 43, 226],
          "brown" => [165, 42, 42],
          "burlywood" => [222, 184, 135],
          "cadetblue" => [95, 158, 160],
          "chartreuse" => [127, 255, 0],
          "chocolate" => [210, 105, 30],
          "coral" => [255, 127, 80],
          "cornflowerblue" => [100, 149, 237],
          "cornsilk" => [255, 248, 220],
          "crimson" => [220, 20, 60],
          "cyan" => [0, 255, 255],
          "darkblue" => [0, 0, 139],
          "darkcyan" => [0, 139, 139],
          "darkgoldenrod" => [184, 134, 11],
          "darkgray" => [169, 169, 169],
          "darkgreen" => [0, 100, 0],
          "darkgrey" => [169, 169, 169],
          "darkkhaki" => [189, 183, 107],
          "darkmagenta" => [139, 0, 139],
          "darkolivegreen" => [85, 107, 47],
          "darkorange" => [255, 140, 0],
          "darkorchid" => [153, 50, 204],
          "darkred" => [139, 0, 0],
          "darksalmon" => [233, 150, 122],
          "darkseagreen" => [143, 188, 143],
          "darkslateblue" => [72, 61, 139],
          "darkslategray" => [47, 79, 79],
          "darkslategrey" => [47, 79, 79],
          "darkturquoise" => [0, 206, 209],
          "darkviolet" => [148, 0, 211],
          "deeppink" => [255, 20, 147],
          "deepskyblue" => [0, 191, 255],
          "dimgray" => [105, 105, 105],
          "dimgrey" => [105, 105, 105],
          "dodgerblue" => [30, 144, 255],
          "firebrick" => [178, 34, 34],
          "floralwhite" => [255, 250, 240],
          "forestgreen" => [34, 139, 34],
          "fuchsia" => [255, 0, 255],
          "gainsboro" => [220, 220, 220],
          "ghostwhite" => [248, 248, 255],
          "gold" => [255, 215, 0],
          "goldenrod" => [218, 165, 32],
          "gray" => [128, 128, 128],
          "green" => [0, 128, 0],
          "greenyellow" => [173, 255, 47],
          "grey" => [128, 128, 128],
          "honeydew" => [240, 255, 240],
          "hotpink" => [255, 105, 180],
          "indianred" => [205, 92, 92],
          "indigo" => [75, 0, 130],
          "ivory" => [255, 255, 240],
          "khaki" => [240, 230, 140],
          "lavender" => [230, 230, 250],
          "lavenderblush" => [255, 240, 245],
          "lawngreen" => [124, 252, 0],
          "lemonchiffon" => [255, 250, 205],
          "lightblue" => [173, 216, 230],
          "lightcoral" => [240, 128, 128],
          "lightcyan" => [224, 255, 255],
          "lightgoldenrodyellow" => [250, 250, 210],
          "lightgray" => [211, 211, 211],
          "lightgreen" => [144, 238, 144],
          "lightgrey" => [211, 211, 211],
          "lightpink" => [255, 182, 193],
          "lightsalmon" => [255, 160, 122],
          "lightseagreen" => [32, 178, 170],
          "lightskyblue" => [135, 206, 250],
          "lightslategray" => [119, 136, 153],
          "lightslategrey" => [119, 136, 153],
          "lightsteelblue" => [176, 196, 222],
          "lightyellow" => [255, 255, 224],
          "lime" => [0, 255, 0],
          "limegreen" => [50, 205, 50],
          "linen" => [250, 240, 230],
          "magenta" => [255, 0, 255],
          "maroon" => [128, 0, 0],
          "mediumaquamarine" => [102, 205, 170],
          "mediumblue" => [0, 0, 205],
          "mediumorchid" => [186, 85, 211],
          "mediumpurple" => [147, 112, 219],
          "mediumseagreen" => [60, 179, 113],
          "mediumslateblue" => [123, 104, 238],
          "mediumspringgreen" => [0, 250, 154],
          "mediumturquoise" => [72, 209, 204],
          "mediumvioletred" => [199, 21, 133],
          "midnightblue" => [25, 25, 112],
          "mintcream" => [245, 255, 250],
          "mistyrose" => [255, 228, 225],
          "moccasin" => [255, 228, 181],
          "navajowhite" => [255, 222, 173],
          "navy" => [0, 0, 128],
          "oldlace" => [253, 245, 230],
          "olive" => [128, 128, 0],
          "olivedrab" => [107, 142, 35],
          "orange" => [255, 165, 0],
          "orangered" => [255, 69, 0],
          "orchid" => [218, 112, 214],
          "palegoldenrod" => [238, 232, 170],
          "palegreen" => [152, 251, 152],
          "paleturquoise" => [175, 238, 238],
          "palevioletred" => [219, 112, 147],
          "papayawhip" => [255, 239, 213],
          "peachpuff" => [255, 218, 185],
          "peru" => [205, 133, 63],
          "pink" => [255, 192, 203],
          "plum" => [221, 160, 221],
          "powderblue" => [176, 224, 230],
          "purple" => [128, 0, 128],
          "rebeccapurple" => [102, 51, 153],
          "red" => [255, 0, 0],
          "rosybrown" => [188, 143, 143],
          "royalblue" => [65, 105, 225],
          "saddlebrown" => [139, 69, 19],
          "salmon" => [250, 128, 114],
          "sandybrown" => [244, 164, 96],
          "seagreen" => [46, 139, 87],
          "seashell" => [255, 245, 238],
          "sienna" => [160, 82, 45],
          "silver" => [192, 192, 192],
          "skyblue" => [135, 206, 235],
          "slateblue" => [106, 90, 205],
          "slategray" => [112, 128, 144],
          "slategrey" => [112, 128, 144],
          "snow" => [255, 250, 250],
          "springgreen" => [0, 255, 127],
          "steelblue" => [70, 130, 180],
          "tan" => [210, 180, 140],
          "teal" => [0, 128, 128],
          "thistle" => [216, 191, 216],
          "tomato" => [255, 99, 71],
          "turquoise" => [64, 224, 208],
          "violet" => [238, 130, 238],
          "wheat" => [245, 222, 179],
          "white" => [255, 255, 255],
          "whitesmoke" => [245, 245, 245],
          "yellow" => [255, 255, 0],
          "yellowgreen" => [154, 205, 50]
        }.freeze

        HEX_PATTERN = /\A#(\h{3}|\h{4}|\h{6}|\h{8})\z/
        private_constant :HEX_PATTERN

        # rgb()/rgba()/hsl()/hsla() in either legacy comma syntax or modern
        # space syntax (`rgb(R G B / A)`), with integer or percentage channels.
        COLOR_FN_PATTERN = /\A(rgba?|hsla?)\((.*)\)\z/im
        private_constant :COLOR_FN_PATTERN

        # Normalizes +value+ to the computed-style serialization.
        # Unrecognized values are returned as-is (never raises).
        #
        # @param value [String] a CSS color value, e.g. "Red", "#0f0", "rgb(0,0,0)"
        # @return [String] "rgb(r, g, b)", "rgba(r, g, b, a)", or +value+ itself
        def normalize(value)
          stripped = value.strip
          lower = stripped.downcase

          return "rgba(0, 0, 0, 0)" if lower == "transparent"

          if (rgb = NAMED[lower])
            return serialize(*rgb)
          end

          if (match = HEX_PATTERN.match(lower))
            return from_hex(match[1])
          end

          if (match = COLOR_FN_PATTERN.match(stripped))
            return normalize_function(match[1].downcase, match[2]) || value
          end

          value
        end

        # Extracts the first color token from a compound value (used by
        # shorthand expansion, e.g. `background: red url(x)`). Returns the
        # normalized color, or nil when no recognizable color is present.
        #
        # @param value [String] a whitespace-separated CSS shorthand value
        # @return [String, nil]
        def extract(value)
          top_level_tokens(value).each do |token|
            lower = token.downcase
            if token.include?("(")
              # Function tokens are skipped wholesale (url(#abc),
              # linear-gradient(red, blue), …) — except rgb()/rgba(),
              # which are themselves colors.
              return normalize(token) if lower.start_with?("rgb(", "rgba(")
            elsif HEX_PATTERN.match?(lower) || lower == "transparent" || NAMED.key?(lower)
              return normalize(token)
            end
          end
          nil
        end

        # Splits +value+ into top-level tokens: whitespace separates tokens
        # only outside parentheses, so a function and its arguments (e.g.
        # `linear-gradient(to right, red)`) stay one token.
        def top_level_tokens(value)
          tokens = []
          current = +""
          depth = 0
          value.each_char do |char|
            case char
            when "("
              depth += 1
              current << char
            when ")"
              depth -= 1 if depth.positive?
              current << char
            when /\s/
              if depth.positive?
                current << char
              elsif !current.empty?
                tokens << current
                current = +""
              end
            else
              current << char
            end
          end
          tokens << current unless current.empty?
          tokens
        end

        # Normalize an rgb()/hsl() function body to rgb()/rgba(). Returns nil
        # when the channels don't parse (the caller keeps the original text).
        def normalize_function(name, args)
          channels, alpha = split_color_args(args)
          return nil unless channels.length == 3

          rgb =
            if name.start_with?("rgb")
              channels.map { |channel| rgb_channel(channel) }
            else
              hsl_to_rgb(hue(channels[0]), percentage(channels[1]), percentage(channels[2]))
            end
          return nil if rgb.any?(&:nil?)

          serialize(*rgb, alpha)
        end

        # [[c1, c2, c3], alpha_or_nil]. Channels are comma- or space-separated;
        # a `/` introduces the alpha (modern syntax), as does a 4th legacy comma
        # value.
        def split_color_args(args)
          args = args.strip
          if args.include?("/")
            main, alpha = args.split("/", 2)
            [main.strip.split(/[\s,]+/), parse_alpha(alpha.strip)]
          else
            parts = args.split(/[\s,]+/)
            parts.length == 4 ? [parts[0, 3], parse_alpha(parts[3])] : [parts, nil]
          end
        end

        # The css-color-4 `none` keyword marks a missing component; in the
        # legacy rgb()/rgba() serialization a computed color uses 0 for it.
        def none?(text) = text.casecmp("none").zero?

        def rgb_channel(channel)
          return 0 if none?(channel)

          if channel.end_with?("%")
            value = Float(channel[0..-2]) / 100.0 * 255
          else
            value = Float(channel)
          end
          value.round.clamp(0, 255)
        rescue ArgumentError, TypeError
          nil
        end

        def parse_alpha(text)
          return 0.0 if none?(text)

          value = text.end_with?("%") ? Float(text[0..-2]) / 100.0 : Float(text)
          value.clamp(0.0, 1.0)
        rescue ArgumentError, TypeError
          nil
        end

        # An <hue>: a bare number or <angle> (deg/grad/rad/turn), wrapped into
        # [0, 360). nil when unparseable.
        def hue(text)
          text = text.downcase
          return 0.0 if none?(text)

          degrees =
            case text
            when /\A(-?\d*\.?\d+)deg\z/ then Float(Regexp.last_match(1))
            when /\A(-?\d*\.?\d+)grad\z/ then Float(Regexp.last_match(1)) * 0.9
            when /\A(-?\d*\.?\d+)rad\z/ then Float(Regexp.last_match(1)) * 180 / Math::PI
            when /\A(-?\d*\.?\d+)turn\z/ then Float(Regexp.last_match(1)) * 360
            when /\A-?\d*\.?\d+\z/ then Float(text)
            end
          degrees && degrees % 360
        end

        def percentage(text)
          return 0.0 if none?(text)
          return nil unless text.end_with?("%")

          (Float(text[0..-2]) / 100.0).clamp(0.0, 1.0)
        rescue ArgumentError, TypeError
          nil
        end

        # HSL -> [r, g, b] (0..255). h in degrees, s/l in 0..1.
        def hsl_to_rgb(h, s, l)
          return [nil] if h.nil? || s.nil? || l.nil?

          chroma = (1 - (2 * l - 1).abs) * s
          secondary = chroma * (1 - ((h / 60.0) % 2 - 1).abs)
          match = l - chroma / 2
          r, g, b =
            case h
            when 0...60 then [chroma, secondary, 0]
            when 60...120 then [secondary, chroma, 0]
            when 120...180 then [0, chroma, secondary]
            when 180...240 then [0, secondary, chroma]
            when 240...300 then [secondary, 0, chroma]
            else [chroma, 0, secondary]
            end
          [r, g, b].map { |channel| ((channel + match) * 255).round }
        end

        # Expands a 3/4/6/8-digit hex body into the rgb()/rgba() form.
        def from_hex(hex)
          hex = hex.chars.map { |c| c * 2 }.join if hex.length <= 4
          r, g, b, a = hex.scan(/\h{2}/).map { |pair| pair.to_i(16) }
          serialize(r, g, b, a && a / 255.0)
        end

        # Builds "rgb(r, g, b)" or, when alpha is present and not 1,
        # "rgba(r, g, b, a)".
        def serialize(r, g, b, alpha = nil)
          return "rgb(#{r}, #{g}, #{b})" if alpha.nil? || alpha == 1

          "rgba(#{r}, #{g}, #{b}, #{format_alpha(alpha)})"
        end

        # Formats an alpha component: round to 5 decimals, drop trailing
        # zeros, and serialize integral values without a decimal point.
        def format_alpha(alpha)
          rounded = alpha.round(5)
          return rounded.to_i.to_s if rounded == rounded.to_i

          rounded.to_s
        end
      end
    end
  end
end
