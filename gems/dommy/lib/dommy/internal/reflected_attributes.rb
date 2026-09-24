# frozen_string_literal: true

module Dommy
  module Internal
    # IDL-attribute reflection for `HTMLElement` and `SVGElement` subclasses.
    #
    # Two layers:
    #
    # 1. **Instance helpers** (`reflected_string` / `set_reflected_string` /
    #    `reflected_boolean` / `set_reflected_boolean`) delegate to the host
    #    element's standard attribute API (`get_attribute` / `set_attribute` /
    #    `has_attribute?` / `remove_attribute`), so case-sensitivity is
    #    inherited from the host's namespace — HTML lowercases, SVG keeps the
    #    spec name (`viewBox`).
    #
    #    - **String**: property mirrors the attribute value. Missing → `""`.
    #    - **Boolean**: property is true iff the attribute is present. Setting
    #      true writes `""`; setting false removes the attribute.
    #
    # 2. **A class-level DSL** (`reflect_string` / `reflect_boolean`) that
    #    declares reflected attributes once and generates BOTH the snake_case
    #    getter/setter pair AND a `js_key => ruby_name` registry entry. A shared
    #    `__js_get__` / `__js_set__` consults that registry, so bridge property
    #    access needs no hand-written `case` arm. This keeps the Ruby accessor,
    #    the JS getter, and the JS setter from drifting apart (the same class of
    #    bug the `js_methods` macro prevents for `__js_call__`).
    #
    #        reflect_string :cx, :cy, :r
    #        reflect_string view_box: "viewBox", class_name: { attr: "class" }
    #        reflect_boolean :disabled, :required
    #
    #    Identifier defaults (override via a String or Hash value):
    #      - js_key (camelCase IDL name) = camelize(ruby_name)
    #      - attr   (content attribute)  = camelize(ruby_name)
    #      - String value overrides attr only:  text_anchor: "text-anchor"
    #      - Hash value overrides either:       tabindex: { js: "tabIndex" }
    module ReflectedAttributes
      def self.included(base)
        base.extend(ClassMethods)
      end

      # One entry per reflected IDL attribute type in HTML §2.6.1, naming the
      # pair of instance helpers that implement that type's getter and setter
      # steps. A declaration says which type an attribute is; this says what the
      # type does, once. A nil getter means the spec writes that half out in
      # prose and the class defines it (see reflect_setter).
      EMPTY_OPTIONS = {}.freeze

      # WebIDL's `long` and `unsigned long`, which bound what a reflected number
      # can be before HTML's own defaults and ranges apply.
      LONG_RANGE = (-2_147_483_648..2_147_483_647).freeze
      UNSIGNED_LONG_MAX = 2_147_483_647
      WRAP = 4_294_967_296

      REFLECTORS = {
        string: %i[reflected_string set_reflected_string],
        url: %i[reflected_url set_reflected_string],
        long: %i[reflected_long set_reflected_long],
        ulong: %i[reflected_ulong set_reflected_ulong],
        boolean: %i[reflected_boolean set_reflected_boolean],
        setter_only: [nil, :set_reflected_string],
      }.freeze

      module ClassMethods
        def reflect_string(*names, **mapped)
          _reflect(:string, names, mapped)
        end

        def reflect_boolean(*names, **mapped)
          _reflect(:boolean, names, mapped)
        end

        # A URL attribute ([ReflectURL]): the setter writes the content attribute
        # unchanged, the getter parses it against the document and returns the
        # serialization.
        def reflect_url(*names, **mapped)
          _reflect(:url, names, mapped)
        end

        # A `long` attribute. `default:` is [ReflectDefault] and `non_negative:`
        # is [ReflectNonNegative] (which makes the setter reject a negative
        # value and the getter fall back to -1 rather than 0).
        #
        #   reflect_long :value                 # li.value, no default
        #   reflect_long start: { default: 1 }  # ol.start
        def reflect_long(*names, **mapped)
          _reflect(:long, names, mapped)
        end

        # An `unsigned long` attribute. `range:` is [ReflectRange], which clamps
        # an out-of-range value to the nearest end instead of falling back;
        # `default:` is [ReflectDefault] and `positive:` is [ReflectPositive].
        #
        #   reflect_ulong :width, :height                              # default 0
        #   reflect_ulong col_span: { attr: "colspan", default: 1,
        #                             range: 1..1000 }
        def reflect_ulong(*names, **mapped)
          _reflect(:ulong, names, mapped)
        end

        # An IDL attribute whose SETTER reflects but whose getter the spec writes
        # out in prose — WebIDL marks these `[ReflectSetter]` rather than
        # `[Reflect]`, and there are a handful: `form.action` returns the
        # document's URL when the content attribute is missing or empty,
        # `base.href` resolves against the document's FALLBACK base URL, `a.href`
        # is HTMLHyperlinkElementUtils. This defines the setter and the bridge
        # registration; the class defines the getter, and the declaration is what
        # says it had to.
        def reflect_setter(*names, **mapped)
          _reflect(:setter_only, names, mapped)
        end

        # Register an EXISTING accessor under its JS name, for a property that
        # is computed rather than mirrored from an attribute — `validity`,
        # `labels`, `valueAsNumber`. It defines nothing; it only tells the
        # shared `__js_get__` which Ruby method answers the key, so the
        # `when "validity" then validity` arms that used to do that can go.
        #
        #   js_readable :validity, :labels, will_validate: "willValidate"
        #
        # WHERE THE LINE IS: a `__js_get__` whose every arm is nothing but a
        # name mapping becomes declarations and the method goes. One that does
        # something first — HTMLFormElement consults its named controls before
        # the builtins — or whose arms read constants rather than call methods
        # (HTMLMediaElement's NETWORK_* ) keeps its `case`. So a `case` in one
        # of these classes means there is logic in it, which is worth knowing
        # when you open one.
        #
        # A class whose `__js_get__` ends in `Bridge::ABSENT` rather than
        # `super` — MutationRecord, DOMRect, and sixty-odd other root objects —
        # keeps its `case` too, however plainly its arms are name mappings.
        # The `__js_get__` here ends in `super`, so such a class would need a
        # terminal module underneath it in the ancestry just to answer ABSENT.
        # Giving the whole family one is a change worth making on its own
        # terms; giving one of them one is worse than the `case`.
        #
        # Element and Document keep their `case` whole, even though about half
        # of each one's arms are name mappings. They do not include this module
        # — HTMLElement does — and including it there to declare those halves
        # would put a second copy of __js_get__ in the ancestry of all
        # sixty-nine element classes, to save arms in two. Not worth the
        # precedence it would move.
        #
        # A String value is the JS name; the default is the camelized one. Use
        # an Array to give one method several JS names (`readonly`/`readOnly`).
        def js_readable(*names, **mapped)
          _register_js_properties(names, mapped, writable: false)
        end

        # The same, for a property JS may also assign.
        def js_accessor(*names, **mapped)
          _register_js_properties(names, mapped, writable: true)
        end

        # What each reflected JS name was DECLARED as: its HTML §2.6.1 type and
        # the content attribute it mirrors, merged across the ancestry. The
        # WebIDL audit reads this and compares it with the reflection the specs'
        # own IDL declares ([Reflect] / [ReflectURL] / [ReflectSetter] and the
        # numeric parameters), so a type that drifts from the spec is a test
        # failure rather than something to notice by eye.
        def reflect_specs
          @__reflect_specs_map__ ||= begin
            inherited = superclass.respond_to?(:reflect_specs) ? superclass.reflect_specs : {}
            inherited.merge(@__reflect_specs__ || {})
          end
        end

        # The JS names this class lets JS assign, merged across the ancestry.
        def writable_property_map
          @__writable_map__ ||= begin
            inherited = superclass.respond_to?(:writable_property_map) ? superclass.writable_property_map : {}
            inherited.merge(@__writable_props__ || {})
          end
        end

        # Merged `js_key => ruby_name` map across the class ancestry (memoized).
        # Recomputed lazily; `_reflect` invalidates the cache when called.
        def reflected_property_map
          @__reflected_map__ ||= begin
            inherited = superclass.respond_to?(:reflected_property_map) ? superclass.reflected_property_map : {}
            inherited.merge(@__reflected_props__ || {})
          end
        end

        private

        def _register_js_properties(names, mapped, writable:)
          @__reflected_props__ ||= {}
          @__writable_props__ ||= {}
          @__reflected_map__ = nil
          @__writable_map__ = nil

          (names.map { |n| [n, nil] } + mapped.to_a).each do |ruby_name, override|
            keys = case override
                   when nil then [_camelize(ruby_name)]
                   when String then [override]
                   when Array then override.map(&:to_s)
                   else raise ArgumentError, "js_readable/js_accessor: unsupported name for #{ruby_name.inspect}"
                   end
            keys.each do |key|
              @__reflected_props__[key] = ruby_name
              @__writable_props__[key] = ruby_name if writable
            end
          end
        end

        def _reflect(type, names, mapped)
          @__reflected_props__ ||= {}
          @__writable_props__ ||= {}
          @__reflect_specs__ ||= {}
          @__reflected_map__ = nil # invalidate memoized merge
          @__writable_map__ = nil
          @__reflect_specs_map__ = nil

          getter, setter = REFLECTORS.fetch(type)

          (names.map { |n| [n, nil] } + mapped.to_a).each do |ruby_name, override|
            attr, js, options = _resolve_identifiers(ruby_name, override)
            define_method(ruby_name) { __send__(getter, attr, options) } if getter
            define_method(:"#{ruby_name}=") { |value| __send__(setter, attr, value, options) }
            @__reflected_props__[js] = ruby_name
            @__writable_props__[js] = ruby_name
            @__reflect_specs__[js] = { type: type, attr: attr }
          end
        end

        # [content attribute, JS name, the type's own parameters] for one
        # declaration. A Hash names any of them; the numeric types read their
        # default / range / sign out of what is left.
        def _resolve_identifiers(ruby_name, override)
          default = _camelize(ruby_name)
          case override
          when nil
            [default, default, EMPTY_OPTIONS]
          when String
            [override, default, EMPTY_OPTIONS]
          when Hash
            [override[:attr] || default, override[:js] || default,
             override.except(:attr, :js).freeze]
          else
            raise ArgumentError, "reflect_*: unsupported mapping for #{ruby_name.inspect}: #{override.inspect}"
          end
        end

        def _camelize(name)
          name.to_s.gsub(/_([a-z0-9])/) { ::Regexp.last_match(1).upcase }
        end
      end

      # Bridge property read: route reflected keys to their accessor (which a
      # subclass may have overridden with coercion), else up the super chain.
      def __js_get__(key)
        prop = self.class.reflected_property_map[key]
        return __send__(prop) if prop

        super
      end

      def __js_set__(key, value)
        prop = self.class.writable_property_map[key]
        return __send__(:"#{prop}=", value) if prop

        super
      end

      private

      def reflected_string(name, _options = nil)
        get_attribute(name).to_s
      end

      def set_reflected_string(name, value, _options = nil)
        set_attribute(name, value.to_s)
      end

      # A URL attribute's getter (HTML §2.6.1): "If contentAttributeValue is
      # null, then return the empty string. Let urlString be the result of
      # encoding-parsing-and-serializing a URL given contentAttributeValue,
      # relative to element's node document. If urlString is not failure, then
      # return urlString. Return contentAttributeValue." So an absent attribute
      # is "", one that does not parse reads back as written, and `src=""`
      # resolves to the document's own address rather than staying empty.
      #
      # The setter is the plain string one: a URL attribute reflects on the way
      # OUT only, and `img.src = "a b"` stores "a b" verbatim.
      def reflected_url(name, _options = nil)
        raw = get_attribute(name)
        return "" if raw.nil?

        resolve_url(raw)
      end


      # HTML's "rules for parsing integers", which every numeric reflection is
      # built on: optional leading ASCII whitespace, an optional sign, then a run
      # of ASCII digits — and it returns THERE, without requiring the run to
      # reach the end of the string. So "12abc" is 12 and "1e3" is 1, and only
      # the absence of digits is an error (nil here); the caller supplies the
      # attribute's default for that. Confirmed against a browser, since the
      # trailing-junk case is a reading of the step list rather than of any prose
      # (dommy-conformance cases/attributes/numeric-reflection.js).
      def parse_html_integer(value)
        return nil if value.nil?

        match = value.to_s.sub(/\A[ \t\n\f\r]+/, "").match(/\A[-+]?\d+/)
        match ? match[0].to_i : nil
      end

      # The same, for the attributes whose value is a valid NON-NEGATIVE integer:
      # a leading "-" is an error rather than a negative number.
      def parse_html_non_negative_integer(value)
        parsed = parse_html_integer(value)
        parsed if parsed && !parsed.negative?
      end

      # A `long` attribute's getter (HTML §2.6.1): the parsed value when it is
      # one and fits a long, else the declared default, else -1 when the
      # attribute is limited to non-negative numbers, else 0.
      def reflected_long(name, options = EMPTY_OPTIONS)
        raw = get_attribute(name)
        unless raw.nil?
          parsed = options[:non_negative] ? parse_html_non_negative_integer(raw) : parse_html_integer(raw)
          return parsed if parsed && LONG_RANGE.cover?(parsed)
        end
        return options[:default] if options.key?(:default)
        return -1 if options[:non_negative]

        0
      end

      # An `unsigned long` attribute's getter. The range is 0..2147483647 unless
      # [ReflectRange] gives another, and that extended attribute is also what
      # decides what an out-of-range value becomes: WITH a range it CLAMPS to the
      # nearer end (`colspan="3000000000"` is 1000), without one it falls back to
      # the default like an unparseable value (`select.size="3000000000"` is 0).
      def reflected_ulong(name, options = EMPTY_OPTIONS)
        range = options[:range]
        minimum = range ? range.first : (options[:positive] ? 1 : 0)
        maximum = range ? range.last : UNSIGNED_LONG_MAX
        parsed = parse_html_non_negative_integer(get_attribute(name))
        if parsed
          return parsed if parsed.between?(minimum, maximum)
          return parsed < minimum ? minimum : maximum if range
        end
        return options[:default] if options.key?(:default)

        minimum
      end

      # A `long` attribute's setter: reject a negative value where the attribute
      # is limited to non-negative ones, and write the number as a valid integer.
      def set_reflected_long(name, value, options = EMPTY_OPTIONS)
        given = to_webidl_long(value)
        if options[:non_negative] && given.negative?
          raise DOMException::IndexSizeError, "#{name} cannot be negative"
        end

        set_attribute(name, given.to_s)
      end

      # An `unsigned long` attribute's setter. A value outside 0..2147483647
      # becomes the default BEFORE it is written, so the attribute never holds
      # one: `cell.colSpan = 3000000000` stores "1". [ReflectRange] has no say
      # here — clamping is the getter's job — and WebIDL has already wrapped a
      # negative value round, which is why `colSpan = -1` also stores "1".
      def set_reflected_ulong(name, value, options = EMPTY_OPTIONS)
        given = to_webidl_ulong(value)
        raise DOMException::IndexSizeError, "#{name} must be positive" if options[:positive] && given.zero?

        minimum = options[:positive] ? 1 : 0
        new_value = options.fetch(:default, minimum)
        new_value = given if given.between?(minimum, UNSIGNED_LONG_MAX)
        set_attribute(name, new_value.to_s)
      end

      # WebIDL's integer conversions, which run before any of the above sees the
      # value: a non-finite number is 0, and anything else truncates and wraps
      # modulo 2**32 (so -1 is 4294967295 as an `unsigned long`).
      def to_webidl_ulong(value) = to_webidl_number(value) % WRAP

      def to_webidl_long(value)
        wrapped = to_webidl_ulong(value)
        wrapped >= WRAP / 2 ? wrapped - WRAP : wrapped
      end

      def to_webidl_number(value)
        number = Float(value, exception: false) || 0.0
        number.finite? ? number.truncate : 0
      end

      def reflected_boolean(name, _options = nil)
        has_attribute?(name)
      end

      def set_reflected_boolean(name, value, _options = nil)
        if value
          set_attribute(name, "")
        elsif has_attribute?(name)
          remove_attribute(name)
        end
      end
    end
  end
end
