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

    # Shared `getElementsByTagNameNS(namespace, localName)` — a live collection
    # of descendants of `root` matching the (namespace, localName) filter, where
    # "*" matches any. An empty-string namespace means the null namespace.
    def self.elements_by_tag_name_ns(root, document, namespace, local_name)
      ns = namespace.to_s
      ns_filter = ns == "*" ? :any : (ns.empty? ? nil : ns)
      local = local_name.to_s
      local_filter = local == "*" ? :any : local
      new do
        # Match on the element's LOCAL NAME (case-sensitive, exact) and
        # namespace — NOT a CSS type selector, which is case-insensitive in an
        # HTML document and keys off the qualified name (so it misses a
        # prefixed `test:body` and wrongly matches `BODY` for `body`).
        root.css("*").filter_map do |node|
          el = document.wrap_node(node)
          next nil unless el

          el_ns = el.respond_to?(:namespace_uri) ? el.namespace_uri : nil
          next nil unless ns_filter == :any || el_ns == ns_filter

          el_local = el.respond_to?(:local_name) ? el.local_name : nil
          next nil unless local_filter == :any || el_local == local_filter

          el
        end
      end
    end

    def length
      to_a.length
    end

    alias size length

    def empty?
      to_a.empty?
    end

    def item(index)
      # `index` is a WebIDL unsigned long, so it wraps modulo 2^32 (e.g. item(2^32)
      # is item(0)); Ruby's modulo also normalizes negatives to that range.
      to_a[index.to_i % 4_294_967_296]
    end

    # `namedItem(name)` returns the first element whose `id` or
    # `name` attribute equals `name`. Returns nil if no match.
    def named_item(name)
      # A numeric argument (`namedItem(2147483648)`) crosses from JS as a Float
      # for values past int32; format it as an integer string so it matches an
      # `id`/`name` attribute like "2147483648" (not "2147483648.0").
      key = (name.is_a?(Float) && name.finite? && name == name.to_i) ? name.to_i.to_s : name.to_s
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
        if s.match?(/\A\d+\z/) && s.to_i < 4_294_967_295 && s == s.to_i.to_s
          # A valid array index is the CANONICAL decimal of 0 ≤ n < 2^32-1 (no
          # leading zeros: "03" is NOT an index, it is a named key). A pure
          # indexed lookup — out of range yields nil (→ undefined), no named
          # fallback.
          item(s.to_i)
        else
          # Non-array-index strings (negative, ≥ 2^32-1, or names) use the named
          # getter; a miss is JS `undefined` (and `"x" in coll` false).
          named_item(s) || (s == "length" ? length : Bridge::ABSENT)
        end
      end
    end

    # WebIDL "supported property names" for HTMLCollection: in tree order, each
    # element contributes its non-empty `id`, then (if it is in the HTML
    # namespace) its non-empty `name` — ignoring duplicates.
    def __js_named_props__
      names = []
      to_a.each do |el|
        next unless el.respond_to?(:__dommy_backend_node__)

        node = el.__dommy_backend_node__
        id = node["id"].to_s
        names << id if !id.empty? && !names.include?(id)

        name = node["name"].to_s
        next if name.empty? || names.include?(name)

        html_ns = !el.respond_to?(:namespace_uri) || el.namespace_uri == "http://www.w3.org/1999/xhtml"
        names << name if html_ns
      end
      names
    end

    include Bridge::Methods
    js_methods %w[item namedItem]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "namedItem"
        named_item(args[0])
      end
    end
  end

  # `HTMLFormControlsCollection` — a form's `elements`. Like HTMLCollection but
  # its named getter returns a RadioNodeList when a name/id matches more than one
  # control (e.g. a radio group), and the single control otherwise.
  class HTMLFormControlsCollection < HTMLCollection
    def named_item(name)
      key = name.to_s
      return nil if key.empty?

      matches = controls_named(key)
      return nil if matches.empty?
      return matches.first if matches.length == 1

      # A live RadioNodeList: a reference held across a DOM mutation reflects the
      # updated group (per spec the named getter returns a live NodeList).
      coll = self
      RadioNodeList.new(matches) { coll.controls_named(key) }
    end

    # The controls in this collection whose id or name equals `key`, in order.
    def controls_named(key)
      to_a.select do |el|
        next false unless el.respond_to?(:__dommy_backend_node__)

        node = el.__dommy_backend_node__
        node["id"].to_s == key || node["name"].to_s == key
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

    # Append (or insert before `before`) an option element. `before` accepts
    # another element (insert before it) or an integer index. Strings/`null`
    # append. The insertion happens in the REFERENCE's parent — which may be an
    # `<optgroup>` — not always the select itself.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__dommy_backend_node__)

      reference =
        case before
        when nil then nil
        when Integer then item(before)
        else before.respond_to?(:__dommy_backend_node__) ? before : nil
        end

      parent = reference&.parent_node
      if reference && parent.respond_to?(:insert_before)
        parent.insert_before(option, reference)
      else
        @owner.append_child(option)
      end

      nil
    end

    def remove(index)
      target = item(index)
      target&.remove
      nil
    end

    # WebIDL "set an indexed property" for HTMLOptionsCollection:
    #   * a null value removes the option at `index`
    #   * otherwise, an in-range index replaces that option; an index at or past
    #     the end appends (padding with blank options for any gap).
    def __set_indexed__(index, option)
      i = index.to_i
      if option.nil?
        remove(i)
        return nil
      end
      return nil unless option.respond_to?(:__dommy_backend_node__)

      current = to_a
      if i < current.length
        @owner.insert_before(option, current[i])
        current[i].remove
      else
        (i - current.length).times { @owner.append_child(@owner.document.create_element("option")) }
        @owner.append_child(option)
      end
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
        # Indexed property setter: `options[i] = option | null`.
        return __set_indexed__(key.to_i, value) if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A\d+\z/))

        return Bridge::UNHANDLED
      end

      nil
    end

    # Adds add/remove on top of the inherited item/namedItem (else -> super).
    js_methods %w[add remove]
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
