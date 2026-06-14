# frozen_string_literal: true

module Dommy
  module Internal
    # Computes the WAI-ARIA *computed role* of an element — the value WPT's
    # `test_driver.get_computed_role` returns and Testing Library's `getByRole`
    # relies on. An explicit, valid `role` attribute wins; otherwise the implicit
    # role is derived from the HTML element (HTML-AAM), with the common
    # context-sensitive cases (header/footer landmarks, named section/form,
    # input/select by type) handled. Layout- or tree-dependent subtleties
    # (heading levels, th scope/row context) are intentionally simplified.
    module AriaRole
      # Abstract roles can never be a computed role; an explicit one is ignored.
      ABSTRACT = %w[
        command composite input landmark range roletype section sectionhead
        select structure widget window
      ].freeze

      # Concrete ARIA 1.2 roles accepted as an explicit `role` token.
      CONCRETE = %w[
        alert alertdialog application article banner blockquote button caption
        cell checkbox code columnheader combobox comment complementary
        contentinfo definition deletion dialog directory document emphasis
        feed figure form generic grid gridcell group heading img insertion link
        list listbox listitem log main mark marquee math menu menubar menuitem
        menuitemcheckbox menuitemradio meter navigation none note option
        paragraph presentation progressbar radio radiogroup region row rowgroup
        rowheader scrollbar search searchbox separator slider spinbutton status
        strong subscript suggestion superscript switch tab table tablist tabpanel
        term textbox time timer toolbar tooltip tree treegrid treeitem
      ].freeze

      # Deprecated role synonyms normalized to their canonical computed role.
      SYNONYMS = { "directory" => "list", "image" => "img", "presentation" => "none" }.freeze

      # Roles that require an author-provided accessible name; without one the
      # token is skipped (role fallback continues to the next token).
      NAME_REQUIRED = %w[form region].freeze

      # Sectioning content under which <header>/<footer> are generic rather than
      # banner/contentinfo landmarks.
      SECTIONING = %w[article aside main nav section].freeze

      module_function

      # The computed role string, or "" when the element maps to no role.
      def compute(element)
        explicit_role(element) || implicit_role(element) || ""
      end

      # The heading level for a heading element: an explicit positive
      # `aria-level`, else the `hN` tag's number, else nil. The role itself
      # stays "heading" (level is a separate ARIA property the a11y tree emits).
      def heading_level(element)
        aria = element.get_attribute("aria-level").to_s
        return aria.to_i if aria.match?(/\A\d+\z/) && aria.to_i.positive?

        tag = element.local_name.to_s.downcase
        tag.match?(/\Ah[1-6]\z/) ? tag[1].to_i : nil
      end

      def explicit_role(element)
        raw = element.get_attribute("role").to_s.strip
        return nil if raw.empty?

        raw.split(/\s+/).each do |token|
          role = SYNONYMS.fetch(token.downcase, token.downcase)
          next unless CONCRETE.include?(role) && !ABSTRACT.include?(role)
          # region / form need an author-supplied name; otherwise fall through to
          # the next token (or the implicit role).
          next if NAME_REQUIRED.include?(role) && !named?(element)
          # A presentational role yields to the implicit role when the element is
          # focusable or carries a global ARIA state/property (conflict
          # resolution); otherwise it stands.
          return nil if role == "none" && presentation_conflict?(element)

          return role
        end
        nil
      end

      def implicit_role(element)
        case element.tag_name.to_s.downcase
        when "a", "area" then element.has_attribute?("href") ? "link" : (element.tag_name.casecmp?("a") ? "generic" : nil)
        when "article" then "article"
        when "aside" then "complementary"
        when "b", "bdi", "bdo", "data", "i", "q", "samp", "small", "span", "u", "div" then "generic"
        when "blockquote" then "blockquote"
        when "button" then "button"
        when "caption" then "caption"
        when "code" then "code"
        when "del" then "deletion"
        when "dialog" then "dialog"
        when "dd" then "definition"
        when "details" then "group"
        when "dfn" then "term"
        when "dt" then "term"
        when "em" then "emphasis"
        when "fieldset" then "group"
        when "figure" then "figure"
        when "footer" then landmark_or_generic(element, "contentinfo")
        when "form" then named?(element) ? "form" : "form"
        when "h1", "h2", "h3", "h4", "h5", "h6" then "heading"
        when "header" then landmark_or_generic(element, "banner")
        when "hr" then "separator"
        when "img" then img_role(element)
        when "input" then input_role(element)
        when "ins" then "insertion"
        when "li" then "listitem"
        when "main" then "main"
        when "mark" then "mark"
        when "math" then "math"
        when "menu", "ol", "ul" then "list"
        when "meter" then "meter"
        when "nav" then "navigation"
        when "option" then "option"
        when "output" then "status"
        when "p" then "paragraph"
        when "progress" then "progressbar"
        when "search" then "search"
        when "section" then named?(element) ? "region" : "generic"
        when "select" then select_role(element)
        when "strong" then "strong"
        when "sub" then "subscript"
        when "sup" then "superscript"
        when "table" then "table"
        when "tbody", "tfoot", "thead" then "rowgroup"
        when "td" then "cell"
        when "textarea" then "textbox"
        when "th" then th_role(element)
        when "time" then "time"
        when "tr" then "row"
        end
      end

      # --- helpers --------------------------------------------------------

      def img_role(element)
        alt = element.get_attribute("alt")
        # An explicitly empty alt makes the image presentational. Return the
        # canonical "none" (not its "presentation" synonym) so the accessibility
        # tree flattens it like any other presentational node.
        alt == "" ? "none" : "img"
      end

      # A <th> is a column or row header. An explicit `scope` wins; otherwise the
      # auto algorithm: a header cell that borders a data cell (<td>) within its
      # row heads that row, so it is a row header; a header cell with only header
      # neighbors heads its column.
      def th_role(element)
        case element.get_attribute("scope").to_s.downcase
        when "row", "rowgroup" then "rowheader"
        when "col", "colgroup" then "columnheader"
        else auto_th_role(element)
        end
      end

      def auto_th_role(element)
        row = element.respond_to?(:parent_element) ? element.parent_element : nil
        return "columnheader" unless row

        cells = row.children.select { |cell| %w[td th].include?(cell.local_name.to_s.downcase) }
        index = cells.index { |cell| same_node?(cell, element) }
        return "columnheader" unless index

        previous = index.zero? ? nil : cells[index - 1]
        neighbors = [previous, cells[index + 1]].compact
        neighbors.any? { |cell| cell.local_name.to_s.casecmp?("td") } ? "rowheader" : "columnheader"
      end

      def same_node?(first, second)
        first && second && first.__dommy_backend_node__ == second.__dommy_backend_node__
      end

      INPUT_ROLES = {
        "button" => "button", "submit" => "button", "reset" => "button",
        "image" => "button", "checkbox" => "checkbox", "radio" => "radio",
        "range" => "slider", "number" => "spinbutton", "email" => "textbox",
        "tel" => "textbox", "text" => "textbox", "url" => "textbox", "search" => "searchbox",
        # type=password has no ARIA role per HTML-AAM (to avoid exposing the
        # value) but Chromium / Playwright expose it as a textbox.
        "password" => "textbox"
      }.freeze

      def input_role(element)
        type = element.get_attribute("type").to_s.downcase
        return "textbox" if type.empty?

        # type=search is searchbox only without a suggestions list; the common
        # case has no list, so map to searchbox.
        INPUT_ROLES[type]
      end

      def select_role(element)
        multiple = element.has_attribute?("multiple")
        size = element.get_attribute("size").to_s.to_i
        multiple || size > 1 ? "listbox" : "combobox"
      end

      # <header>/<footer> are landmarks only when not scoped to sectioning
      # content; otherwise generic.
      def landmark_or_generic(element, landmark)
        node = element.respond_to?(:__dommy_backend_node__) ? element.__dommy_backend_node__&.parent : nil
        while node && node.respond_to?(:name)
          return "generic" if SECTIONING.include?(node.name.to_s.downcase)

          node = node.parent
        end
        landmark
      end

      def named?(element)
        return true if present?(element.get_attribute("aria-label"))
        return true if present?(element.get_attribute("aria-labelledby"))

        present?(element.get_attribute("title"))
      end

      def present?(value)
        !value.nil? && !value.to_s.empty?
      end

      # Presentation conflict resolution (simplified): a focusable element or one
      # with a global ARIA attribute keeps its implicit role.
      def presentation_conflict?(element)
        return true if present?(element.get_attribute("tabindex"))

        %w[aria-label aria-labelledby aria-describedby].any? { |a| present?(element.get_attribute(a)) }
      end
    end
  end
end
