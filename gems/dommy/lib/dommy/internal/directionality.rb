# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's element directionality (HTML §3.2.6.4): the computed "ltr" / "rtl"
    # that `:dir()` and `getComputedStyle().direction` report. It comes from the
    # `dir` attribute — ltr / rtl explicitly, auto by the first strong
    # directional character, absent by inheritance — with <bdi> defaulting to
    # auto and input / textarea auto reading their value.
    module Directionality
      # Scripts whose characters are bidirectional type R or AL — the strong
      # right-to-left characters the auto heuristic looks for. Ruby exposes no
      # bidi property, so this is the script approximation for the scripts that
      # matter.
      RTL_SCRIPT = /\p{Hebrew}|\p{Arabic}|\p{Syriac}|\p{Thaana}|\p{Nko}|\p{Samaritan}|\p{Mandaic}/

      module_function

      # The element's computed direction: "ltr" or "rtl". Memoized per element
      # for the document's current style generation — `direction_of` walks the
      # ancestor chain (and, for dir=auto, the subtree), and the cascade asks
      # every element for it, so recomputing per read would be quadratic.
      def direction_of(element)
        generation = cache_generation(element)
        return compute_direction(element) unless generation

        memo = element.instance_variable_get(:@__direction_memo__)
        return memo[1] if memo && memo[0] == generation

        value = compute_direction(element)
        element.instance_variable_set(:@__direction_memo__, [generation, value])
        value
      end

      # The direction the element itself declares (its `dir` attribute, or
      # <bdi>'s auto default), or nil when it inherits one. The cascade uses this
      # so a `dir`-less element inherits the parent's computed `direction` like
      # any other inherited property, while an explicit dir still wins.
      def explicit_direction(element)
        dir_state(element) ? direction_of(element) : nil
      end

      def compute_direction(element)
        case dir_state(element)
        when "ltr" then "ltr"
        when "rtl" then "rtl"
        when "auto" then auto_direction(element)
        else
          parent = element.respond_to?(:parent_element) ? element.parent_element : nil
          parent ? direction_of(parent) : "ltr"
        end
      end

      # "ltr" / "rtl" / "auto" from the element's own `dir` attribute, or nil
      # when it has none. <bdi> defaults to auto.
      def dir_state(element)
        if element.respond_to?(:has_attribute?) && element.has_attribute?("dir")
          value = element.get_attribute("dir").to_s.strip.downcase
          return value if %w[ltr rtl auto].include?(value)

          return "ltr"
        end
        return "auto" if element.respond_to?(:local_name) && element.local_name.to_s.casecmp?("bdi")

        nil
      end

      def auto_direction(element)
        if element.respond_to?(:local_name) && %w[input textarea].include?(element.local_name.to_s.downcase)
          return strong_string_direction(element.value.to_s) || "ltr"
        end

        strong_in_tree(element) || "ltr"
      end

      # Walk the element's descendants in tree order: a strong character
      # decides, and a descendant with its own explicit `dir` decides by that
      # direction without looking at its text.
      def strong_in_tree(element)
        element.child_nodes.each do |child|
          if child.is_a?(Dommy::TextNode)
            direction = strong_string_direction(child.data.to_s)
            return direction if direction
          elsif child.respond_to?(:local_name)
            next if %w[script style].include?(child.local_name.to_s.downcase)

            state = dir_state(child)
            return state if state == "ltr" || state == "rtl"

            direction = strong_in_tree(child)
            return direction if direction
          end
        end
        nil
      end

      # The direction of the first strong (bidi L / AL / R) character in `text`,
      # or nil when there is none.
      def strong_string_direction(text)
        text.each_char do |char|
          return "rtl" if char.match?(RTL_SCRIPT)
          return "ltr" if char.match?(/\p{L}/)
        end
        nil
      end

      # The style generation the memo is keyed on, or nil when there is no
      # document to key on (then every read recomputes).
      def cache_generation(element)
        doc = element.respond_to?(:owner_document) ? element.owner_document : nil
        doc.respond_to?(:style_generation) ? doc.style_generation : nil
      end
    end
  end
end
