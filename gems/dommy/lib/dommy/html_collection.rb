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

    # `count` and `at` are the same fast path LiveList has, for a node's
    # element children.
    def initialize(count: nil, at: nil, &compute)
      @compute = compute
      @count = count
      @at = at
    end

    # Shared `getElementsByTagNameNS(namespace, localName)` — a live collection
    # of descendants of `root` matching the (namespace, localName) filter, where
    # "*" matches any. An empty-string namespace means the null namespace.
    HTML_NAMESPACE = Internal::Namespaces::HTML

    # WHATWG `getElementsByTagName(qualifiedName)` — a live collection filtered
    # by qualified name. "*" matches any. In an HTML document, HTML-namespace
    # elements match case-insensitively (ASCII), while other-namespace elements
    # (and everything in a non-HTML document) match case-sensitively.
    def self.elements_by_tag_name(root, document, qualified_name)
      qn = qualified_name.to_s
      html_doc = document.html_document?
      qn_lower = ascii_downcase(qn)
      new do
        root.css("*").filter_map do |node|
          el = document.wrap_node(node)
          next nil unless el
          next el if qn == "*"

          el_qn = qualified_name_of(el)
          el_ns = el.namespace_uri
          # For an HTML-namespace element in an HTML document, only the QUERY is
          # ASCII-lowercased — the element's own qualified name is compared as-is
          # (so an uppercase-localName HTML element, e.g. createElementNS(html,
          # "I"), never matches "i" or "I").
          match =
            if html_doc && el_ns == HTML_NAMESPACE
              el_qn == qn_lower
            else
              el_qn == qn
            end
          match ? el : nil
        end
      end
    end

    # The element's qualified name (prefix:localName, or just localName). The
    # backend node name can't be trusted — the HTML parser lowercases it — so
    # rebuild it from the case-preserving local name and prefix. The prefix is
    # read through the Ruby accessor, never `__js_get__("prefix")`: that is the
    # JS bridge protocol, and on a form it goes through the named getter first —
    # so a form containing a control named "prefix" would report itself as
    # `prefix:form` and vanish from getElementsByTagName("form").
    def self.qualified_name_of(el)
      local = el.local_name.to_s
      prefix = el.element_prefix
      prefix = nil if prefix.nil? || prefix.to_s.empty?
      prefix ? "#{prefix}:#{local}" : local
    end

    # ASCII-only lowercase (A-Z -> a-z), leaving non-ASCII code points intact,
    # per the spec's "converted to ASCII lowercase".
    def self.ascii_downcase(str)
      str.gsub(/[A-Z]/) { |c| (c.ord + 32).chr }
    end

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

          el_ns = el.namespace_uri
          next nil unless ns_filter == :any || el_ns == ns_filter

          el_local = el.local_name
          next nil unless local_filter == :any || el_local == local_filter

          el
        end
      end
    end

    def length
      @count ? @count.call : to_a.length
    end

    alias size length

    def empty?
      length.zero?
    end

    def item(index)
      # `index` is a WebIDL unsigned long, so it wraps modulo 2^32 (e.g. item(2^32)
      # is item(0)); Ruby's modulo also normalizes negatives to that range.
      i = index.to_i % 4_294_967_296
      @at ? @at.call(i) : to_a[i]
    end

    # The supported-property-name a `namedItem` argument stands for. A numeric
    # argument (`namedItem(2147483648)`) crosses from JS as a Float for values
    # past int32; format it as an integer string so it matches an `id`/`name`
    # attribute like "2147483648" (not "2147483648.0").
    #
    # Protected rather than inlined because HTMLFormControlsCollection
    # overrides #named_item, and had its own `name.to_s` — the same rule, minus
    # this one.
    def named_key(name)
      (name.is_a?(Float) && name.finite? && name == name.to_i) ? name.to_i.to_s : name.to_s
    end
    protected :named_key

    # `namedItem(name)` returns the first element whose `id` or
    # `name` attribute equals `name`. Returns nil if no match.
    def named_item(name)
      key = named_key(name)
      return nil if key.empty?

      to_a.find do |el|
        node = el.__dommy_backend_node__
        # `id` matches any element; `name` matches only HTML-namespace elements
        # (WebIDL supported property names), so a null-namespace element's
        # `name` attribute isn't a supported name. Both are read in no
        # namespace.
        next true if Backend.no_namespace_attribute_value(node, "id").to_s == key

        html_ns = el.namespace_uri == Internal::Namespaces::HTML
        html_ns && Backend.no_namespace_attribute_value(node, "name").to_s == key
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
        node = el.__dommy_backend_node__
        id = Backend.no_namespace_attribute_value(node, "id").to_s
        names << id if !id.empty? && !names.include?(id)

        name = Backend.no_namespace_attribute_value(node, "name").to_s
        next if name.empty? || names.include?(name)

        html_ns = el.namespace_uri == Internal::Namespaces::HTML
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
      key = named_key(name)
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
        node = el.__dommy_backend_node__
        Backend.no_namespace_attribute_value(node, "id").to_s == key ||
          Backend.no_namespace_attribute_value(node, "name").to_s == key
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

    # HTML `add(element, before)`: `element` is an HTMLOptionElement or
    # HTMLOptGroupElement (anything else is a TypeError), `before` an element
    # to insert ahead of, an index into the collection, or null to append. The
    # insertion happens in the reference's parent — which may be an
    # `<optgroup>` — not always the select itself.
    def add(element, before = nil)
      unless element.is_a?(HTMLOptionElement) || element.is_a?(HTMLOptGroupElement)
        raise Bridge::TypeError, "The provided value is not of type '(HTMLOptionElement or HTMLOptGroupElement)'."
      end

      before = nil if before.equal?(Bridge::UNDEFINED)
      before_element = before.is_a?(Node)
      if before_element && !before.is_a?(HTMLElement)
        raise Bridge::TypeError, "The provided value is not of type '(HTMLElement or long)'."
      end

      if element.contains?(@owner)
        raise DOMException::HierarchyRequestError, "The new element is an ancestor of the select."
      end
      if before_element && !@owner.contains?(before)
        raise DOMException::NotFoundError, "The reference element is not a descendant of the select."
      end
      return nil if before_element && before.equal?(element)

      reference =
        if before_element then before
        elsif before.nil? then nil
        else item(Internal::WebIDL.long(before))
        end
      parent = reference ? reference.parent_node : @owner
      parent.insert_before(element, reference)
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
    def __internal_set_indexed__(index, option)
      i = index.to_i
      if option.nil?
        remove(i)
        return nil
      end
      return nil unless option.is_a?(Node) && option.__dommy_backend_node__

      current = to_a
      if i < current.length
        current[i].parent_node.replace_child(option, current[i])
      else
        append_new_options(i - current.length)
        @owner.append_child(option)
      end
      nil
    end

    # HTML "append new option elements": `count` blank options, inserted into
    # the select at once through a fragment.
    def append_new_options(count)
      return if count <= 0

      doc = @owner.document
      fragment = doc.create_document_fragment
      count.times { fragment.append_child(doc.create_element("option")) }
      @owner.append_child(fragment)
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
    #
    # HTML: growing to more than 100,000 options does nothing at all.
    MAX_LENGTH = 100_000

    def length=(new_length)
      n = Internal::WebIDL.unsigned_long(new_length)
      current = to_a
      if n < current.length
        current[n..].each(&:remove)
      elsif n > current.length
        return nil if n > MAX_LENGTH

        append_new_options(n - current.length)
      end
      nil
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
        return __internal_set_indexed__(key.to_i, value) if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A\d+\z/))

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
