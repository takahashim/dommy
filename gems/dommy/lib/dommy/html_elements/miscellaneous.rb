# frozen_string_literal: true

module Dommy
  # The elements that add little or nothing to HTMLElement.
  #
  # One of the HTML element groups; html_elements.rb lists them all. Their
  # reflected attributes (`ol.start`, `li.value`, and the obsolete `type` /
  # `compact` of the lists) are declared from the IDL by
  # Internal::IdlReflection.
  class HTMLOListElement < HTMLElement
  end

  class HTMLUListElement < HTMLElement
  end

  class HTMLLIElement < HTMLElement
  end

  class HTMLTimeElement < HTMLElement
  end

  class HTMLDataElement < HTMLElement
  end

  # Element interfaces that are otherwise plain HTMLElement subclasses — their
  # own IDL adds little beyond the base, but they must be distinct types so
  # `createElement("col") instanceof HTMLTableColElement` (and cloneNode
  # identity) holds. `col`/`colgroup` share HTMLTableColElement per spec.

  class HTMLDirectoryElement < HTMLElement; end

  class HTMLDListElement < HTMLElement; end

  class HTMLFontElement < HTMLElement
  end

  class HTMLQuoteElement < HTMLElement
  end

  class HTMLModElement < HTMLElement
  end

  # `<menu>`: its one IDL attribute, the obsolete `compact`, is declared from
  # the IDL.
  class HTMLMenuElement < HTMLElement
  end

  # `<marquee>` (HTML §16.2, obsolete but implemented). Its attributes are
  # plain reflections declared from the IDL — `behavior` and `direction`
  # included: the IDL reflects them as plain strings, even though the content
  # attributes are enumerated — except `loop`, which the spec writes out.
  # Nothing is rendered, so the element is only ever turned on or off.
  class HTMLMarqueeElement < HTMLElement
    js_methods %w[start stop]
    js_accessor loop_: "loop"

    # "When it is created, it is turned on."
    def turned_on? = !@__marquee_turned_off

    def start
      @__marquee_turned_off = false
      nil
    end

    def stop
      @__marquee_turned_off = true
      nil
    end

    # The marquee loop count: the `loop` attribute by the rules for parsing
    # integers when that is a number of at least 1, else −1.
    def loop_
      count = parse_html_integer(__internal_attribute_value__("loop"))
      count && count >= 1 ? count : -1
    end

    # "On setting, if the new value is different than the element's marquee
    # loop count and either greater than zero or equal to −1, must set the
    # element's loop content attribute … to the valid integer that represents
    # the new value. (Other values are ignored.)"
    def loop_=(value)
      count = to_webidl_long(value)
      return if count == loop_
      return unless count.positive? || count == -1

      __internal_set_attribute_value__("loop", count.to_s)
    end

    def __js_call__(method, args)
      case method
      when "start" then start
      when "stop" then stop
      else super
      end
    end
  end

  # Identity-only subclasses — useful for `instanceof` / `is_a?` checks
  # in consumer code, even though they don't add reflected IDL attrs
  # beyond what HTMLElement already exposes.
  class HTMLDivElement < HTMLElement
  end

  class HTMLSpanElement < HTMLElement
  end

  class HTMLParagraphElement < HTMLElement
  end

  class HTMLHeadingElement < HTMLElement
  end

  class HTMLBRElement < HTMLElement
  end

  class HTMLHRElement < HTMLElement
  end

  class HTMLPreElement < HTMLElement
  end
end
