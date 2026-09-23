# frozen_string_literal: true

require_relative "cascaded_declarations"
require_relative "property_registry"
require_relative "custom_properties"

module Dommy
  module Internal
    module CSS
      # The lengths a computed value can resolve against without layout: the
      # element's own and the root's font-size, and the viewport. Carried
      # together because they are always needed together — em, rem, vw and vh
      # are one question asked four ways.
      LengthContext = Struct.new(:font_size, :root_font_size, :viewport_width, :viewport_height) do
        def to_h
          {font_size: font_size, root_font_size: root_font_size,
           viewport_width: viewport_width, viewport_height: viewport_height}
        end

        # The same context with the element's own font-size replaced — em and %
        # inside a font-size resolve against the PARENT's, so font-size is
        # computed with the parent's in this slot and everything else with the
        # element's.
        def with_font_size(px) = self.class.new(px, root_font_size, viewport_width, viewport_height)
      end

      # The cascade's second half: from the winning declarations to the frozen
      # computed-style Hash.
      #
      # The order below is forced by the spec, and is why this is an object
      # rather than a sequence of calls: custom properties must resolve before
      # anything substitutes var(), font-size must compute before any other
      # property can resolve em, and `color` must compute before currentColor
      # can be replaced anywhere else.
      #
      # `style_for` answers another element's computed style (the parent's, the
      # root's). It is a parameter so this file never calls back into Cascade,
      # which owns the memo that makes those lookups cheap.
      class ComputedStyleBuilder
        ROOT_FONT_SIZE_PX = 16.0

        def initialize(element, document, index, style_for, pseudo_element: nil)
          @element = element
          @document = document
          @index = index
          @style_for = style_for
          @pseudo_element = pseudo_element
        end

        def build
          @parent_styles = parent_styles
          @custom = resolve_custom_properties
          @winners = CascadedDeclarations.collect_longhands(@element, @index,
            pseudo_element: @pseudo_element, custom: @custom)

          result = {}
          lengths = compute_font_size_into(result)
          compute_registered_properties(result, lengths)
          carry_unregistered_properties(result)
          resolve_current_color!(result)
          # Computed custom properties are part of the computed style: the
          # children inherit them from here, and getPropertyValue("--x")
          # reads them.
          result.merge!(@custom)
          result
        end

        private

        # A pseudo-element inherits from its originating element; an element
        # from its parent (nil at the root — the initial values then apply).
        def parent_styles
          return @style_for.call(@element) if @pseudo_element

          parent = @element.parent_element
          parent ? @style_for.call(parent) : nil
        end

        # The element's computed custom property set: the parent's (custom
        # properties inherit), overlaid with this element's cascaded
        # declarations, then var()-resolved with cycle detection. An explicit
        # `initial` (or an unresolvable value) removes the entry — the
        # guaranteed-invalid value.
        def resolve_custom_properties
          winners = CascadedDeclarations.collect_custom(@element, @index, pseudo_element: @pseudo_element)
          merged = @parent_styles ? @parent_styles.select { |key, _| key.start_with?("--") } : {}
          winners.each_property do |name|
            next unless name.start_with?("--")

            value = winners.value_for(name, @parent_styles)
            value.nil? ? merged.delete(name) : merged[name] = value
          end
          CustomProperties.resolve_all(merged)
        end

        # font-size first: every other property's em resolves against it.
        # Returns the LengthContext the rest of the pass uses.
        def compute_font_size_into(result)
          root_px = root_font_size
          parent_px = px_of(inherited_font_size) || ROOT_FONT_SIZE_PX
          vw, vh = viewport
          # em and % inside a font-size are relative to the PARENT's font-size.
          parent_lengths = LengthContext.new(parent_px, root_px, vw, vh)

          result["font-size"] = compute_font_size(cascaded("font-size"), parent_lengths)
          parent_lengths.with_font_size(px_of(result["font-size"]))
        end

        def compute_registered_properties(result, lengths)
          PropertyRegistry::PROPERTIES.each_key do |name|
            next if name == "font-size"

            result[name] = PropertyRegistry.computed_value(name, specified(name).to_s, **lengths.to_h)
          end
        end

        # The value that enters the computed-value transform: the cascaded one,
        # or the inherit/initial default fill. `color: currentColor` means
        # "inherit the color" (there is no other color to point at), resolved
        # here so the value other properties' currentColor resolves against is
        # real.
        def specified(name)
          value = cascaded(name)
          value ||= if PropertyRegistry.inherited?(name) && @parent_styles
            @parent_styles[name]
          else
            PropertyRegistry.initial(name)
          end
          return value unless name == "color" && value.to_s.casecmp("currentcolor").zero?

          @parent_styles ? @parent_styles["color"] : PropertyRegistry.initial("color")
        end

        # Unregistered properties degrade to their cascaded value as-is
        # (no inheritance, no normalization).
        def carry_unregistered_properties(result)
          @winners.each_property do |name|
            next if PropertyRegistry.known?(name) || name.start_with?("--") || result.key?(name)

            value = cascaded(name)
            result[name] = value if value
          end
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

        def cascaded(name) = @winners.value_for(name, @parent_styles)

        def inherited_font_size
          @parent_styles ? @parent_styles["font-size"] : PropertyRegistry.initial("font-size")
        end

        def root_font_size
          root = @document.document_element
          return ROOT_FONT_SIZE_PX if root.nil? || @element.equal?(root)

          px_of(@style_for.call(root)["font-size"]) || ROOT_FONT_SIZE_PX
        end

        # font-size's own computation: em/%/rem/absolute/viewport units resolve
        # against the parent / root computed font-size and the viewport, none of
        # which needs layout. Keywords and unhandled values pass through as
        # specified.
        def compute_font_size(specified, parent_lengths)
          return inherited_font_size if specified.nil?

          if (match = specified.match(/\A(-?\d+(?:\.\d+)?)%\z/i))
            return PropertyRegistry.format_px(match[1].to_f / 100.0 * parent_lengths.font_size)
          end

          PropertyRegistry.evaluate_calc(specified, **parent_lengths.to_h) ||
            PropertyRegistry.resolve_length(specified, **parent_lengths.to_h) || specified
        end

        # The viewport size in px for resolving vw/vh, from the document's
        # window media environment. nil when the document has no window
        # (fragments, DOMParser output) — vw/vh then stay as specified.
        def viewport
          view = @document.respond_to?(:default_view) ? @document.default_view : nil
          env = view&.media_environment
          env ? [env.viewport_width, env.viewport_height] : [nil, nil]
        end

        def px_of(value)
          match = value.to_s.match(/\A(-?\d+(?:\.\d+)?)px\z/i)
          match && match[1].to_f
        end
      end
    end
  end
end
