# frozen_string_literal: true

require_relative "css/style_cache"

module Dommy
  module Internal
    # HTML's element directionality (HTML §3.2.6.4): the computed "ltr" / "rtl"
    # that `:dir()` and `getComputedStyle().direction` report. It comes from the
    # `dir` attribute — ltr / rtl explicitly, auto by the first strong
    # directional character, otherwise the parent's — with <bdi> defaulting to
    # auto and the textual form controls reading their value.
    module Directionality
      # Scripts whose characters are bidirectional type R or AL — the strong
      # right-to-left characters the auto heuristic looks for. Ruby exposes no
      # bidi property, so this is the script approximation for the scripts that
      # matter.
      RTL_SCRIPT = /\p{Hebrew}|\p{Arabic}|\p{Syriac}|\p{Thaana}|\p{Nko}|\p{Samaritan}|\p{Mandaic}/

      # The dir attribute's keywords, each naming its own state. Anything else
      # (and no attribute at all) is the Undefined state.
      DIR_KEYWORDS = %w[ltr rtl auto].freeze

      # The input types that are NOT auto-directionality form-associated
      # elements. Every other state — including an invalid type, which is the
      # Text state — reads its value under dir=auto.
      NON_TEXTUAL_INPUT_TYPES = %w[
        checkbox radio file image number range date time datetime-local month week color
      ].freeze

      # The descendants the contained-text heuristic skips along with their
      # subtrees, besides any element with a dir attribute of its own.
      SKIPPED_FOR_AUTO = %w[bdi script style textarea].freeze

      module_function

      # The element's computed direction: "ltr" or "rtl". Memoized in the
      # document's StyleCache — `direction_of` walks the ancestor chain (and,
      # for dir=auto, the subtree), and the cascade asks every element for it,
      # so recomputing per read would be quadratic.
      def direction_of(element)
        document = element.owner_document
        return compute_direction(element) unless document.respond_to?(:__css_style_cache__)

        CSS::StyleCache.for(document).direction(element) { compute_direction(element) }
      end

      # The dir attribute's state — "ltr", "rtl" or "auto" — or nil for the
      # Undefined state: no attribute, a value that is not one of the keywords
      # (matched ASCII case-insensitively, nothing trimmed), or an element that
      # is not an HTML element, for which `dir` means nothing.
      def dir_state(element)
        return nil unless html_element?(element)

        dir_keyword(element.get_attribute("dir"))
      end

      # The state a dir attribute value names, or nil (Undefined) for a
      # missing or invalid one.
      def dir_keyword(value)
        return nil if value.nil?

        keyword = value.downcase(:ascii)
        keyword if DIR_KEYWORDS.include?(keyword)
      end

      # Whether an element with this local name and dir attribute value takes
      # its direction from text (or a control's value): dir=auto, or a <bdi>
      # left in the Undefined state. Plain strings, so the mutation bookkeeping
      # can ask it of backend nodes without wrapping them.
      def text_dependent?(local_name, dir_value)
        keyword = dir_keyword(dir_value)
        keyword == "auto" || (keyword.nil? && local_name.to_s.casecmp?("bdi"))
      end

      # The `dir` IDL attribute: the content attribute limited to only known
      # values — its keyword in lowercase, or "" in the Undefined state.
      def reflected_dir(element) = dir_state(element) || ""

      # The direction the element itself declares, or nil when it inherits one
      # — the elements the HTML rendering section's UA rules set `direction`
      # on: any HTML element with a dir attribute (valid or not), <bdi>, and
      # <input type=tel>. The cascade uses this so a `dir`-less element
      # inherits the parent's computed `direction` like any other inherited
      # property, while an explicit dir still wins.
      def explicit_direction(element)
        declares = html_element?(element) &&
          (element.has_attribute?("dir") || named?(element, "bdi") || tel_input?(element))
        declares ? direction_of(element) : nil
      end

      def compute_direction(element)
        case dir_state(element)
        when "ltr" then "ltr"
        when "rtl" then "rtl"
        when "auto" then auto_direction(element) || "ltr"
        else
          if named?(element, "bdi") then auto_direction(element) || "ltr"
          elsif tel_input?(element) then "ltr"
          else parent_direction(element)
          end
        end
      end

      # The parent node's directionality: a shadow root passes on its host's.
      def parent_direction(element)
        parent = element.parent_node
        parent = parent.host if parent.is_a?(ShadowRoot)
        parent.is_a?(Element) ? direction_of(parent) : "ltr"
      end

      # HTML's "auto directionality": "ltr", "rtl", or nil when nothing decides.
      def auto_direction(element)
        if auto_directionality_form_associated?(element)
          value = element.value.to_s
          return strong_string_direction(value) || (value.empty? ? nil : "ltr")
        end
        if named?(element, "slot") && element.get_root_node.is_a?(ShadowRoot)
          assigned = element.assigned_nodes
          return assigned_nodes_direction(assigned) unless assigned.empty?
        end

        contained_text_direction(element)
      end

      # A slot's assigned nodes decide in order: a Text node by its text, an
      # element by its contained text (its own root included in the skip rules).
      def assigned_nodes_direction(nodes)
        nodes.each do |node|
          direction =
            if node.is_a?(TextNode) then strong_string_direction(node.data.to_s)
            else contained_text_direction(node, exclude_root: true)
            end
          return direction if direction
        end
        nil
      end

      # HTML's "contained text auto directionality": the first strong character
      # among the descendant Text nodes in tree order, skipping — with their
      # subtrees — bdi / script / style / textarea and any element whose dir
      # attribute is not Undefined. A slot in a shadow tree answers with its
      # host's direction.
      def contained_text_direction(element, exclude_root: false)
        return nil if exclude_root && skipped_for_auto?(element)

        element.child_nodes.each do |child|
          if child.is_a?(TextNode)
            direction = strong_string_direction(child.data.to_s)
            return direction if direction
          elsif child.is_a?(Element)
            next if skipped_for_auto?(child)
            return direction_of(child.get_root_node.host) if named?(child, "slot") && child.get_root_node.is_a?(ShadowRoot)

            direction = contained_text_direction(child)
            return direction if direction
          end
        end
        nil
      end

      def skipped_for_auto?(element)
        SKIPPED_FOR_AUTO.any? { |name| named?(element, name) } || !dir_state(element).nil?
      end

      # The input types listed as auto-directionality form-associated, and
      # <textarea>.
      def auto_directionality_form_associated?(element)
        return true if named?(element, "textarea")

        named?(element, "input") && !NON_TEXTUAL_INPUT_TYPES.include?(element.type)
      end

      def tel_input?(element) = named?(element, "input") && element.type == "tel"

      # The direction of the first strong (bidi L / AL / R) character in `text`,
      # or nil when there is none.
      def strong_string_direction(text)
        text.each_char do |char|
          return "rtl" if char.match?(RTL_SCRIPT)
          return "ltr" if char.match?(/\p{L}/)
        end
        nil
      end

      def html_element?(element) = element.is_a?(HTMLElement)

      def named?(element, local_name)
        html_element?(element) && element.local_name == local_name
      end
    end
  end
end
