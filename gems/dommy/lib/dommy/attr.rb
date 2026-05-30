# frozen_string_literal: true

module Dommy
  # `Attr` — wraps an HTML attribute as a Node-like object. In real
  # DOM each attribute on an element is an Attr; `el.getAttributeNode`
  # returns the instance, `attr.value = "x"` mutates the element's
  # attribute, `attr.ownerElement` points back to the element.
  #
  # We represent two states:
  #   - "owned" — the Attr is attached to an Element. value reads/writes
  #     go through the element's Nokogiri attribute slot.
  #   - "detached" — created via `document.createAttribute(name)` but
  #     not yet attached. Value is stored locally; `setAttributeNode`
  #     transfers it to an element.
  class Attr
    attr_reader :name, :namespace_uri, :prefix, :local_name

    def initialize(name, owner: nil, value: "", namespace_uri: nil, prefix: nil, local_name: nil)
      qname = name.to_s
      @owner = owner
      @detached_value = value.to_s
      if namespace_uri && !namespace_uri.to_s.empty?
        # Namespaced attributes preserve case and carry prefix / localName.
        @name = qname
        @namespace_uri = namespace_uri.to_s
        @prefix = prefix
        @local_name = (local_name || qname.split(":", 2).last).to_s
      else
        # Null-namespace (HTML) attributes are lower-cased, as before.
        @name = qname.downcase
        @namespace_uri = nil
        @prefix = nil
        @local_name = @name
      end
    end

    # The Element this attr is on, or nil if detached.
    def owner_element
      @owner
    end

    def value
      if @owner
        if @namespace_uri
          Backend.get_attribute_ns(@owner.__dommy_backend_node__, @namespace_uri, @local_name).to_s
        else
          @owner.__dommy_backend_node__[@name].to_s
        end
      else
        @detached_value
      end
    end

    def value=(new_value)
      if @owner
        if @namespace_uri
          @owner.set_attribute_ns(@namespace_uri, @name, new_value.to_s)
        else
          @owner.set_attribute(@name, new_value.to_s)
        end
      else
        @detached_value = new_value.to_s
      end
    end

    def __js_get__(key)
      case key
      when "name"
        @name
      when "value"
        value
      when "nodeName"
        @name
      when "nodeValue"
        value
      when "ownerElement"
        @owner
      when "localName"
        @local_name
      when "namespaceURI"
        @namespace_uri
      when "prefix"
        @prefix
      when "nodeType"
        2
      end
    end

    def __js_set__(key, val)
      case key
      when "value", "nodeValue"
        self.value = val
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[cloneNode]
    def __js_call__(method, _args)
      case method
      when "cloneNode"
        Attr.new(@name, owner: nil, value: value,
                        namespace_uri: @namespace_uri, prefix: @prefix, local_name: @local_name)
      end
    end

    # Internal: called by Element when the attr is being transferred
    # to (or detached from) an Element.
    def __internal_attach__(element)
      @owner = element
      @detached_value = ""
      nil
    end

    def __internal_detach__
      cached = value
      @owner = nil
      @detached_value = cached
      nil
    end
  end

  # `Element.attributes` returns this. Iterable, `.length`, `.item(i)`,
  # `.getNamedItem(name)`, `.removeNamedItem(name)`, `.setNamedItem(attr)`,
  # plus property-style access (`attributes.id`, `attributes.class`).
  #
  # NamedNodeMap is *live* — it re-reads the element's Nokogiri
  # attributes on every access so DOM mutations are reflected.
  class NamedNodeMap
    include Enumerable

    def initialize(element)
      @element = element
    end

    def length
      @element.__dommy_backend_node__.attribute_nodes.size
    end

    alias size length

    def item(index)
      node = @element.__dommy_backend_node__.attribute_nodes[index.to_i]
      node && attr_for(node)
    end

    # Build a namespace-aware Attr wrapper from a backend attribute node.
    def attr_for(attr_node)
      info = Backend.attribute_ns_info(attr_node)
      Attr.new(info[:qualified_name], owner: @element,
                                      namespace_uri: info[:namespace_uri],
                                      prefix: info[:prefix],
                                      local_name: info[:local_name])
    end

    def get_named_item(name)
      key = name.to_s.downcase
      return nil unless @element.__dommy_backend_node__.key?(key)

      Attr.new(key, owner: @element)
    end

    def set_named_item(attr)
      return nil unless attr.is_a?(Attr)

      key = attr.name
      val = attr.value
      attr.__internal_attach__(@element)
      @element.set_attribute(key, val)
      attr
    end

    def remove_named_item(name)
      key = name.to_s.downcase
      return nil unless @element.__dommy_backend_node__.key?(key)

      attr = Attr.new(key, owner: nil, value: @element.__dommy_backend_node__[key].to_s)
      @element.remove_attribute(key)
      attr
    end

    def each
      @element.__dommy_backend_node__.attribute_nodes.each do |a|
        yield attr_for(a)
      end
    end

    # ----- Namespaced named-item access (getNamedItemNS etc.) -----

    def get_named_item_ns(namespace, local_name)
      node = @element.__dommy_backend_node__.attribute_nodes.find do |a|
        info = Backend.attribute_ns_info(a)
        info[:local_name] == local_name.to_s &&
          (info[:namespace_uri] || nil) == (namespace.to_s.empty? ? nil : namespace.to_s)
      end
      node && attr_for(node)
    end

    def set_named_item_ns(attr)
      return nil unless attr.is_a?(Attr)

      previous = attr.namespace_uri ? get_named_item_ns(attr.namespace_uri, attr.local_name) : nil
      val = attr.value
      attr.__internal_attach__(@element)
      if attr.namespace_uri
        @element.set_attribute_ns(attr.namespace_uri, attr.name, val)
      else
        @element.set_attribute(attr.name, val)
      end
      previous
    end

    def remove_named_item_ns(namespace, local_name)
      existing = get_named_item_ns(namespace, local_name)
      return nil unless existing

      detached = Attr.new(existing.name, owner: nil, value: existing.value,
                                         namespace_uri: existing.namespace_uri,
                                         prefix: existing.prefix, local_name: existing.local_name)
      @element.remove_attribute_ns(namespace, local_name)
      detached
    end

    # Property-style access — `el.attributes.id`, `el.attributes["class"]`.
    def [](key)
      case key
      when Integer
        item(key)
      else
        get_named_item(key)
      end
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        # Numeric key = item(i); string key = named item
        if key.is_a?(Integer) || key.to_s.match?(/\A\d+\z/)
          item(key.to_i)
        else
          get_named_item(key)
        end
      end
    end

    include Bridge::Methods
    js_methods %w[item getNamedItem setNamedItem removeNamedItem
                  getNamedItemNS setNamedItemNS removeNamedItemNS]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "getNamedItem"
        get_named_item(args[0])
      when "setNamedItem"
        set_named_item(args[0])
      when "removeNamedItem"
        remove_named_item(args[0])
      when "getNamedItemNS"
        get_named_item_ns(args[0], args[1])
      when "setNamedItemNS"
        set_named_item_ns(args[0])
      when "removeNamedItemNS"
        remove_named_item_ns(args[0], args[1])
      end
    end

    def method_missing(name, *args)
      attr = get_named_item(name)
      attr || super
    end

    def respond_to_missing?(name, include_private = false)
      @element.__dommy_backend_node__.key?(name.to_s.downcase) || super
    end
  end
end
