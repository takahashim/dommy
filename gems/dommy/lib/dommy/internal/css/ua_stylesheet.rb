# frozen_string_literal: true

require_relative "parser"
require_relative "../directionality"

module Dommy
  module Internal
    module CSS
      # The minimal UA stylesheet (HTML Standard, Rendering section): the
      # non-rendering / hidden defaults that visibility detection depends on,
      # display type defaults, and details/dialog behavior. Kept deliberately
      # small — anything an author sheet usually overrides anyway is omitted.
      #
      # Selectors must stay within what both DOM backends can match
      # (so no case-insensitive attribute flags, no state pseudo-classes). The
      # few rules that need more are evaluated per element instead, by
      # #element_declarations.
      module UAStylesheet
        # The elements the stylesheet below makes block-level. The fallback for
        # code that asks "is this block-level?" when no CSS layer is available
        # (the accname algorithm, innerText).
        BLOCK_LEVEL_TAGS = %w[
          address article aside blockquote caption dd details div dl dt fieldset
          figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr legend li main
          menu nav ol p pre section summary table tbody td tfoot th thead tr ul
        ].freeze

        TEXT = <<~CSS
          [hidden] { display: none }
          area, base, basefont, datalist, head, link, meta, noembed,
          noframes, param, rp, script, style, template, title { display: none }
          input[type="hidden"] { display: none }
          dialog:not([open]) { display: none }
          details:not([open]) > *:not(summary) { display: none }

          html, body, address, article, aside, blockquote, details, dialog,
          dd, div, dl, dt, fieldset, figcaption, figure, footer, form,
          h1, h2, h3, h4, h5, h6, header, hgroup, hr, legend, main, nav, ol, p,
          pre, section, summary, ul { display: block }
          li { display: list-item }
          table { display: table }
          caption { display: table-caption }
          colgroup { display: table-column-group }
          col { display: table-column }
          thead { display: table-header-group }
          tbody { display: table-row-group }
          tfoot { display: table-footer-group }
          tr { display: table-row }
          td, th { display: table-cell }

          b, strong { font-weight: 700 }
          i, em, cite, var, dfn { font-style: italic }
          pre, code, kbd, samp { font-family: monospace }
          pre { white-space: pre }
          textarea { white-space: pre-wrap }
          center { text-align: center }
        CSS

        module_function

        def rules
          @rules ||= Parser.parse(TEXT).freeze
        end

        # The UA rules the sheet above cannot carry because they need `:dir()`,
        # as the [property, value, specificity] declarations they give the
        # element:
        #
        #   [dir]:dir(ltr), bdi:dir(ltr), input[type=tel i]:dir(ltr) { direction: ltr }
        #   [dir]:dir(rtl), bdi:dir(rtl) { direction: rtl }
        #
        # An element none of them selects gets no declaration, so its
        # `direction` inherits like any other inherited property.
        def element_declarations(element)
          return [] unless element.is_a?(HTMLElement)

          specificities = []
          specificities << [0, 2, 0] if element.has_attribute?("dir")
          specificities << [0, 1, 1] if element.local_name == "bdi"
          tel = element.local_name == "input" && element.type == "tel"
          return [] if specificities.empty? && !tel

          direction = Directionality.direction_of(element)
          specificities << [0, 2, 1] if tel && direction == "ltr"
          return [] if specificities.empty?

          [["direction", direction, specificities.max]]
        end
      end
    end
  end
end
