# frozen_string_literal: true

module Dommy
  # The elements that add little or nothing to HTMLElement.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  class HTMLOListElement < HTMLElement
    reflect_string :type
    reflect_boolean :reversed
    reflect_long start: { default: 1 }
  end

  class HTMLUListElement < HTMLElement
  end

  class HTMLLIElement < HTMLElement
    reflect_long :value
  end

  class HTMLTimeElement < HTMLElement
    reflect_string date_time: "datetime"
  end

  class HTMLDataElement < HTMLElement
    reflect_string :value
  end

  # Element interfaces that are otherwise plain HTMLElement subclasses — their
  # own IDL adds little beyond the base, but they must be distinct types so
  # `createElement("col") instanceof HTMLTableColElement` (and cloneNode
  # identity) holds. `col`/`colgroup` share HTMLTableColElement per spec.

  class HTMLDirectoryElement < HTMLElement; end

  class HTMLDListElement < HTMLElement; end

  class HTMLFontElement < HTMLElement
    reflect_string :color, :face, :size
  end

  class HTMLQuoteElement < HTMLElement
    reflect_url :cite
  end

  class HTMLModElement < HTMLElement
    reflect_url :cite
    reflect_string date_time: "datetime"
  end

  # Identity-only subclasses — useful for `instanceof` / `is_a?` checks
  # in consumer code, even though they don't add reflected IDL attrs
  # beyond what HTMLElement already exposes.

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
