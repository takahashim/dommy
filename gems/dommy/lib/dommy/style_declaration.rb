# frozen_string_literal: true

module Dommy
  # CSSStyleDeclaration as an element's `style` attribute exposes it,
  # and the DOMRect geometry answers.
  #
  # Lived in element.rb, which is for Element.
  class StyleDeclaration
    include Enumerable

    def initialize(element)
      @element = element
    end

    # CSSStyleDeclaration interface: cssText serializes the parsed declaration
    # block (`prop: value;` joined by spaces), dropping invalid declarations.
    # The setter reparses and rewrites the `style` attribute in that form.
    def css_text
      serialize_properties(declarations)
    end

    def css_text=(value)
      write_properties(parse_declarations(value))
    end

    # CSSOM getPropertyPriority: "important" for a declaration flagged
    # `!important`, "" otherwise (including for an absent property).
    def get_property_priority(name)
      declarations[property_key(name)]&.last.to_s
    end

    def get_property_value(name)
      properties[property_key(name)].to_s
    end

    def length
      properties.size
    end

    # `style[0]` returns the property name at that index (matches
    # `style.item(i)` in real DOM). String key form (`style["color"]`)
    # is a convenience shortcut for `getPropertyValue`.
    def [](key)
      if key.is_a?(Integer)
        properties.keys[key]
      else
        properties[property_key(key)]
      end
    end

    def []=(name, value)
      set_property(name, value)
    end

    def each(&blk)
      properties.keys.each(&blk)
    end

    # camelCase JS property accessors → kebab-case CSS property name.
    # `style.backgroundColor = "red"` becomes `background-color: red`.
    def method_missing(name, *args)
      key = method_to_css_name(name)
      if name.to_s.end_with?("=")
        set_property(key, args.first)
      elsif properties.key?(key)
        properties[key]
      else
        ""
      end
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def __js_get__(key)
      case key
      when "cssText"
        css_text
      when "length"
        length
      else
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          self[key.to_i]
        else
          # An unset CSS property reads as "" (per CSSStyleDeclaration), not nil —
          # `el.style.display` is "" until assigned, which `v-show` and other
          # display-toggling code compares against.
          properties[method_to_css_name(key)] || ""
        end
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText"
        self.css_text = value
      else
        set_property(method_to_css_name(key), value)
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[setProperty removeProperty getPropertyValue getPropertyPriority item]
    def __js_call__(method, args)
      case method
      when "setProperty"
        set_property(args[0], args[1], args[2])
      when "removeProperty"
        remove_property(args[0])
      when "getPropertyValue"
        get_property_value(args[0])
      when "getPropertyPriority"
        get_property_priority(args[0])
      when "item"
        properties.keys[args[0].to_i]
      else
        nil
      end
    end

    # CSSOM setProperty(property, value, priority?): an empty value removes the
    # declaration, and `priority` must be either the empty string or an ASCII
    # case-insensitive "important" — any other priority abandons the call.
    #
    # Public: `method_missing` treats every unknown name as a CSS property, so a
    # private CSSOM method would be silently swallowed rather than called.
    def set_property(name, value, priority = nil)
      key = property_key(name)
      decls = declarations
      if value.nil? || value.to_s.empty?
        # Step 3 runs BEFORE the priority check, so an empty value removes the
        # declaration even when the priority is nonsense. Removing a property
        # that was not set changes nothing, so the style attribute is left alone
        # — no rewrite, and no mutation record.
        return nil unless decls.key?(key)

        decls.delete(key)
      else
        # Step 4: an invalid priority leaves the declaration block untouched
        # (it is NOT normalized to "" and stored).
        normalized = normalize_priority(priority)
        return nil if normalized.nil?

        # An invalid value is dropped rather than stored, and dropping it is not
        # a change either.
        return nil unless Internal::CSS::Parser.valid_declaration_value?(value.to_s.strip)

        entry = [value.to_s, normalized]
        return nil if decls[key] == entry

        decls[key] = entry
      end

      write_properties(decls)
      nil
    end

    def remove_property(name)
      key = property_key(name)
      decls = declarations
      # Removing a property that was not set changes nothing, so the style
      # attribute is left as it is — no rewrite, and no mutation record.
      return "" unless decls.key?(key)

      removed = decls.delete(key)
      write_properties(decls)
      removed&.first.to_s
    end

    private

    # CSSOM normalizes every property name it is handed, the same way the
    # declaration block's own names are normalized.
    def property_key(name)
      Internal::CSS::Parser.property_name(name)
    end

    def method_to_css_name(name)
      s = name.to_s.sub(/=\z/, "")
      # snake_case (Ruby idiomatic) → kebab; camelCase (JS idiomatic) → kebab.
      s.include?("_") ? s.tr("_", "-") : s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }
    end

    # The declaration block as an ordered { property => [value, priority] } hash,
    # where priority is "important" or "".
    def declarations
      parse_declarations(@element.__dommy_backend_node__["style"].to_s)
    end

    # Just the values, for the value-only readers (getPropertyValue, indexing,
    # `style.color`) — an `!important` flag is metadata, never part of the value.
    def properties
      declarations.transform_values(&:first)
    end

    # "important" / "" for a valid priority, nil when the whole call is a no-op.
    def normalize_priority(priority)
      Internal::CssPriority.normalize(priority)
    end

    # The block, as the CSSOM sees it: an ordered { property => [value,
    # priority] } hash. The parsing itself — the name's case rule, the
    # `!important` split, the value validation, and which of two declarations
    # for one property survives — is Internal::CSS::Parser's, shared with the
    # other declaration block the CSSOM exposes (a style rule's).
    def parse_declarations(str)
      Internal::CSS::Parser.parse_block(str).transform_values do |decl|
        [decl.value, decl.important ? "important" : ""]
      end
    end

    def serialize_properties(decls)
      decls.map do |k, (v, priority)|
        "#{k}: #{v}#{priority.to_s.empty? ? "" : " !important"};"
      end.join(" ")
    end

    def write_properties(decls)
      # Per CSSOM, mutating an inline style declaration serializes it back to the
      # `style` content attribute. An emptied declaration serializes to "" and
      # the attribute STAYS present (style="") — it is removed only via an
      # explicit removeAttribute("style"), never as a side effect of clearing the
      # last property.
      @element.set_attribute("style", serialize_properties(decls))
    end
  end

  # Stub `DOMRect` for `getBoundingClientRect` — no layout engine,
  # so all values are 0. Consumer code that uses these for *relative*
  # positioning sees zeroed values; absolute layout assertions need
  # the real browser.
  class DOMRect
    attr_reader :x, :y, :width, :height

    def initialize(x: 0, y: 0, width: 0, height: 0)
      @x = x
      @y = y
      @width = width
      @height = height
    end

    def top
      @y
    end

    def left
      @x
    end

    def right
      @x + @width
    end

    def bottom
      @y + @height
    end

    def __js_get__(key)
      case key
      when "x", "left"
        @x
      when "y", "top"
        @y
      when "width"
        @width
      when "height"
        @height
      when "right"
        @x + @width
      when "bottom"
        @y + @height
      else
        Bridge::ABSENT
      end
    end

    def js_null?
      false
    end
  end
end
