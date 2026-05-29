# frozen_string_literal: true

module Dommy
  # `HTMLCollection` — live, ordered set of Element nodes. Distinct
  # from `NodeList` in two ways:
  #
  #   - Always element-only (Node types other than Element are skipped)
  #   - Supports `namedItem(name)` lookup by `id` or `name` attribute
  #
  # Live behavior: pass an evaluator block (called `&compute`) that
  # returns the current element list on every access. Each query
  # re-evaluates, so mutations to the parent tree are reflected
  # immediately.
  #
  # Intentionally NOT a subclass of Array; spec semantics demand
  # `Array.isArray(html_collection) === false` in real browsers, and
  # mirroring that here helps tests written against MDN behavior.
  class HTMLCollection
    include Enumerable

    def initialize(&compute)
      @compute = compute
    end

    def length
      to_a.length
    end

    alias size length

    def empty?
      to_a.empty?
    end

    def item(index)
      i = index.to_i
      return nil if i < 0

      to_a[i]
    end

    # `namedItem(name)` returns the first element whose `id` or
    # `name` attribute equals `name`. Returns nil if no match.
    def named_item(name)
      key = name.to_s
      return nil if key.empty?

      to_a.find do |el|
        next false unless el.respond_to?(:__dommy_backend_node__)

        el.__dommy_backend_node__["id"].to_s == key || el.__dommy_backend_node__["name"].to_s == key
      end
    end

    # `[]` supports both integer index (`coll[0]`, `coll[-1]`) and
    # string name (`coll["myId"]`). Negative indices are interpreted
    # Ruby-style (offset from the end), even though the spec's
    # `item(i)` is positive-only.
    def [](key)
      case key
      when Integer
        to_a[key]
      when /\A-?\d+\z/
        to_a[key.to_i]
      else
        named_item(key)
      end
    end

    def first(n = nil)
      n.nil? ? to_a.first : to_a.first(n)
    end

    def last(n = nil)
      n.nil? ? to_a.last : to_a.last(n)
    end

    def each(&blk)
      to_a.each(&blk)
    end

    def to_a
      @compute.call
    end

    def __js_get__(key)
      case key
      when "length"
        length
      when Integer
        item(key)
      else
        s = key.to_s
        if s.match?(/\A\d+\z/)
          item(s.to_i)
        else
          named_item(s) || (s == "length" ? length : nil)
        end
      end
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[item namedItem].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "namedItem"
        named_item(args[0])
      end
    end
  end

  # `HTMLOptionsCollection` — specialized `<select>.options` collection.
  # Adds `add(option, before?)`, `remove(index)`, the `selectedIndex`
  # getter/setter, and a `length=` setter that truncates or extends.
  #
  # Live, like the parent class. Constructed by `HTMLSelectElement`
  # and passed its owner; mutations route through the owner's tree.
  class HTMLOptionsCollection < HTMLCollection
    def initialize(owner, &compute)
      super(&compute)
      @owner = owner
    end

    # Append (or insert before `before`) an option element. `before`
    # accepts either another option (insert before that node) or an
    # integer index. Strings/`null` append.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__dommy_backend_node__)

      case before
      when nil
        @owner.append_child(option)
      when Integer
        anchor = item(before)
        anchor ? @owner.insert_before(option, anchor) : @owner.append_child(option)
      else
        if before.respond_to?(:__dommy_backend_node__)
          @owner.insert_before(option, before)
        else
          @owner.append_child(option)
        end
      end

      nil
    end

    def remove(index)
      target = item(index)
      target&.remove
      nil
    end

    def selected_index
      @owner.selected_index
    end

    def selected_index=(value)
      @owner.selected_index = value
    end

    # Setter mirrors `<select>.options.length = n` — destructive resize.
    # Shrinks by removing trailing options, grows by appending blank
    # `<option>`s. Real browsers do the same.
    def length=(new_length)
      n = new_length.to_i
      current = to_a
      if n < current.length
        current[n..].each(&:remove)
      elsif n > current.length
        (n - current.length).times { @owner.append_child(@owner.document.create_element("option")) }
      end

      n
    end

    def __js_get__(key)
      case key
      when "selectedIndex"
        selected_index
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "selectedIndex"
        self.selected_index = value
      when "length"
        self.length = value
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    # Adds add/remove on top of the inherited item/namedItem (else -> super).
    JS_METHOD_NAMES = (HTMLCollection::JS_METHOD_NAMES + %w[add remove]).freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "add"
        add(args[0], args[1])
      when "remove"
        remove(args[0])
      else
        super
      end
    end
  end
end
