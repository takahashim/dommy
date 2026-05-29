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
    attr_reader :name

    def initialize(name, owner: nil, value: "")
      @name = name.to_s.downcase
      @owner = owner
      @detached_value = value.to_s
    end

    # The Element this attr is on, or nil if detached.
    def owner_element
      @owner
    end

    def value
      if @owner
        @owner.__node__[@name].to_s
      else
        @detached_value
      end
    end

    def value=(new_value)
      if @owner
        @owner.set_attribute(@name, new_value.to_s)
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
        @name
      when "namespaceURI"
        nil
      when "nodeType"
        2
      end
    end

    def __js_set__(key, val)
      case key
      when "value", "nodeValue"
        self.value = val
      end

      nil
    end

    def __js_call__(method, _args)
      case method
      when "cloneNode"
        Attr.new(@name, owner: nil, value: value)
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
      @element.__node__.attribute_nodes.size
    end

    alias size length

    def item(index)
      name = @element.__node__.attribute_nodes[index.to_i]&.name
      name && Attr.new(name, owner: @element)
    end

    def get_named_item(name)
      key = name.to_s.downcase
      return nil unless @element.__node__.key?(key)

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
      return nil unless @element.__node__.key?(key)

      attr = Attr.new(key, owner: nil, value: @element.__node__[key].to_s)
      @element.remove_attribute(key)
      attr
    end

    def each(&blk)
      @element.__node__.attribute_nodes.each do |a|
        yield Attr.new(a.name, owner: @element)
      end
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
      end
    end

    def method_missing(name, *args)
      attr = get_named_item(name)
      attr || super
    end

    def respond_to_missing?(name, include_private = false)
      @element.__node__.key?(name.to_s.downcase) || super
    end
  end
end
