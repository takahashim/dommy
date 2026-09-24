# frozen_string_literal: true

module Dommy
  # DOMTokenList (`classList`, `relList`) and DOMStringMap (`dataset`) —
  # the two live views over one attribute's text.
  #
  # Lived in element.rb, which is for Element.
  class ClassList
    include Enumerable

    # `attribute` is the content attribute this token list reflects ("class" for
    # `classList`, "rel" for `relList`, "sandbox", "sizes", "for", …).
    def initialize(element, attribute = "class")
      @element = element
      @attribute = attribute
    end

    def length
      class_tokens.length
    end

    alias size length

    def item(index)
      i = index.to_i
      return nil if i.negative?

      class_tokens[i]
    end

    def value
      @element.__dommy_backend_node__[@attribute].to_s
    end

    def value=(new_value)
      @element.set_attribute(@attribute, new_value.to_s)
    end

    # Spec: contains() does NOT validate (no SyntaxError on empty).
    def contains?(token)
      class_tokens.include?(token.to_s)
    end

    # DOMTokenList membership. Defined explicitly (rather than inheriting
    # Enumerable#include?, which re-iterates via #each) so a class-selector match
    # is a single Array#include? over the cached tokens — the hot path under a
    # querySelector-heavy SPA.
    def include?(token)
      class_tokens.include?(token.to_s)
    end

    def add(*tokens)
      update_tokens { |existing| existing | normalize_tokens(tokens) }
      nil
    end

    def remove(*tokens)
      update_tokens { |existing| existing - normalize_tokens(tokens) }
      nil
    end

    def replace(old_token, new_token)
      # Spec order: both tokens' empty checks (SyntaxError) precede both
      # whitespace checks (InvalidCharacterError) — so replace(" ", "") is a
      # SyntaxError (the empty newToken), not an InvalidCharacterError.
      old_s = stringify_token(old_token)
      new_s = stringify_token(new_token)
      raise DOMException::SyntaxError, "token is empty" if old_s.empty? || new_s.empty?
      if old_s.match?(/[ \t\n\f\r]/) || new_s.match?(/[ \t\n\f\r]/)
        raise DOMException::InvalidCharacterError, "token contains whitespace"
      end

      tokens = class_tokens
      idx = tokens.index(old_s)
      return false unless idx

      # class_tokens returns the cached token array; dup before mutating so the
      # in-place assignment can't corrupt the cache (whose key is still the old
      # raw attribute string, which would then hand stale tokens to later reads).
      updated = tokens.dup
      updated[idx] = new_s
      @element.set_attribute(@attribute, updated.uniq.join(" "))
      true
    end

    def [](index)
      item(index)
    end

    def each(&blk)
      class_tokens.each(&blk)
    end

    def to_a
      class_tokens.dup
    end

    def to_s
      value
    end

    def __js_get__(key)
      case key
      when "length"
        length
      when "value"
        value
      else
        # Indexed getter: `classList[i]` is an undefined-returning indexed
        # property — out-of-range or negative indices yield JS `undefined`
        # (unlike `item(i)`, which returns null). Returning Ruby nil here would
        # marshal as JS null, so use the UNDEFINED sentinel.
        if key.is_a?(Integer) || key.to_s.match?(/\A-?\d+\z/)
          i = key.to_i
          token = i.negative? ? nil : class_tokens[i]
          token.nil? ? Bridge::UNDEFINED : token
        else
          Bridge::ABSENT # unknown non-index property
        end
      end
    end

    def __js_set__(key, val)
      case key
      when "value"
        self.value = val
      end

      nil
    end

    include Bridge::Methods
    # NOTE: `supports` is intentionally absent — for the class attribute's token
    # list it must throw a TypeError, which `list.supports(...)` (not a function)
    # already does.
    js_methods %w[add remove contains toggle replace item toString]
    def __js_call__(method, args)
      case method
      when "add"
        update_tokens { |tokens| tokens | normalize_tokens(args) }
        Bridge::UNDEFINED
      when "remove"
        update_tokens { |tokens| tokens - normalize_tokens(args) }
        Bridge::UNDEFINED
      when "contains"
        # contains() does not validate; null coerces to the string "null".
        class_tokens.include?(stringify_token(args[0]))
      when "toggle"
        toggle(args[0], args[1])
      when "replace"
        replace(args[0], args[1])
      when "item"
        item(args[0])
      when "toString"
        value
      else
        nil
      end
    end

    private

    def toggle(token, force)
      name = validate_token(token)
      present = class_tokens.include?(name)
      force_given = !(force.nil? || force.equal?(Bridge::UNDEFINED))

      # Spec: toggle runs the update steps only when it actually adds or removes.
      # With an explicit force that already matches the current state it's a
      # no-op — the attribute is left byte-for-byte untouched (no re-serialize).
      if force_given
        want = !!force
        return want if want == present

        update_tokens { |tokens| want ? tokens | [name] : tokens - [name] }
        return want
      end

      desired = !present
      update_tokens { |tokens| desired ? tokens | [name] : tokens - [name] }
      desired
    end

    # USVString coercion of a token argument: JS `null` becomes the string
    # "null" (so `add(null)` adds the token "null"), not the empty string.
    def stringify_token(token)
      token.nil? ? "null" : token.to_s
    end

    # Spec: any empty-string argument throws SyntaxError; any token
    # containing ASCII whitespace throws InvalidCharacterError. Applies
    # to add / remove / replace / toggle.
    def normalize_tokens(args)
      args.map { |t| validate_token(t) }
    end

    def validate_token(token)
      s = stringify_token(token)
      raise DOMException::SyntaxError, "token is empty" if s.empty?
      raise DOMException::InvalidCharacterError, "token contains whitespace: #{s.inspect}" if s.match?(/\s/)

      s
    end

    # The DOMTokenList token set: the class attribute parsed as an *ordered set*
    # (whitespace-split, duplicates removed preserving first-seen order). length,
    # item, iteration, and contains all operate on this set; `value`/`toString`
    # return the raw attribute. ASCII whitespace per the spec is space/tab/LF/FF/CR.
    def class_tokens
      raw = @element.__dommy_backend_node__[@attribute].to_s
      # Cache the parsed token list keyed by the raw attribute string: a class
      # selector match re-reads this for every element on every querySelector,
      # and the split/reject/uniq dominated heavy-SPA load profiles. The key is
      # the raw value itself, so any change (add/remove/className=, or a direct
      # backend mutation) yields a different key and transparently recomputes.
      cached = @token_cache
      return cached[1] if cached && cached[0] == raw

      tokens = raw.split(/[ \t\n\f\r]+/).reject(&:empty?).uniq
      @token_cache = [raw, tokens]
      tokens
    end

    # DOMTokenList "update steps": serialize the (deduplicated) token set back to
    # the class attribute. add/remove/replace always run this, so duplicates
    # collapse and whitespace normalizes even on a no-op token. The one carve-out
    # (per spec) is an empty set with no existing attribute — don't create one.
    def update_tokens
      tokens = yield(class_tokens)
      return if tokens.empty? && !@element.__dommy_backend_node__.key?(@attribute)

      @element.set_attribute(@attribute, tokens.join(" "))
    end
  end

  # `Element#dataset` proxy. `el.dataset.fooBar` reads / writes
  # `data-foo-bar` per the HTMLOrForeignElement.dataset spec
  # (camelCase ↔ kebab-case round-trip).

  # `Element#dataset` proxy. `el.dataset.fooBar` reads / writes
  # `data-foo-bar` per the HTMLOrForeignElement.dataset spec
  # (camelCase ↔ kebab-case round-trip).
  class DatasetMap
    def initialize(element)
      @element = element
    end

    def __js_get__(key)
      name = key.to_s
      # A name with `-` + lowercase is not a supported property name (`data--foo`
      # maps to `Foo`, never to `-foo`).
      return Bridge::ABSENT if name.match?(/-[a-z]/)

      # A missing data-* attribute reads as JS `undefined` (and `"foo" in dataset`
      # is false), per DOMStringMap semantics.
      value = @element.__dommy_backend_node__[attr_name(name)]
      value.nil? ? Bridge::ABSENT : value
    end

    def __js_set__(key, value)
      name = key.to_s
      # DOMStringMap setter: a `-` + lowercase would make the name unround-trippable.
      raise DOMException::SyntaxError, "#{name.inspect} is not a valid dataset name" if name.match?(/-[a-z]/)

      attribute = attr_name(name)
      unless attribute.match?(/\A[^\s<>"'\/=&]+\z/)
        raise DOMException::InvalidCharacterError, "#{attribute.inspect} is not a valid attribute name"
      end

      @element.set_attribute(attribute, value.to_s)
      nil
    end

    # Named deleter (`delete el.dataset.foo`): removes the data-* attribute. A
    # `-` + lowercase name is silently left alone (it names nothing to delete).
    def __js_delete__(key)
      name = key.to_s
      return true if name.match?(/-[a-z]/)

      @element.remove_attribute(attr_name(name))
      true
    end

    def __js_call__(_method, _args)
      nil
    end

    # WebIDL "supported property names" for DOMStringMap: each `data-*`
    # attribute's name with the `data-` prefix stripped and `-x` sequences
    # camel-cased (`data-date-of-birth` → `dateOfBirth`, `data-` → ``).
    def __js_named_props__
      Backend.attribute_nodes(@element.__dommy_backend_node__).filter_map do |a|
        name = Backend.attribute_ns_info(a)[:qualified_name]
        next unless name.start_with?("data-")

        name.sub(/\Adata-/, "").gsub(/-([a-z])/) { ::Regexp.last_match(1).upcase }
      end
    end

    private

    def attr_name(key)
      "data-#{key.to_s.gsub(/[A-Z]/) { |m| "-#{m.downcase}" }}"
    end
  end

  # Stub `DOMRect` for `getBoundingClientRect` — no layout engine,
  # so all values are 0. Consumer code that uses these for *relative*
  # positioning sees zeroed values; absolute layout assertions need
  # the real browser.
end
