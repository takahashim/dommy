# frozen_string_literal: true

require_relative "parser"

module Dommy
  module Internal
    module CSS
      # The minimal UA stylesheet (HTML Standard, Rendering section): the
      # non-rendering / hidden defaults that visibility detection depends on,
      # display type defaults, and details/dialog behavior. Kept deliberately
      # small — anything an author sheet usually overrides anyway is omitted.
      #
      # Selectors must stay within what both DOM backends can match
      # (so no case-insensitive attribute flags, no state pseudo-classes).
      module UAStylesheet
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
          center { text-align: center }
        CSS

        module_function

        def rules
          @rules ||= Parser.parse(TEXT).freeze
        end
      end
    end
  end
end
