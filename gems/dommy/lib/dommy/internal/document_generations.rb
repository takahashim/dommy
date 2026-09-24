# frozen_string_literal: true

module Dommy
  module Internal
    # The counters the caches hang on: one for the tree's shape, one for what
    # a selector can match, one for what the cascade computes. A mutation bumps
    # the ones it can actually invalidate, which is the whole point — a text
    # edit inside a <p> must not throw away the rule index.
    #
    # Host contract: @__css_style_cache__ and #__internal_style_sheet_elements__.
    module DocumentGenerations
      def style_generation
        @style_generation || 0
      end

      def dom_generation
        @dom_generation || 0
      end

      # Moves only on childList mutations — the coarsest epoch. Keys memos
      # whose value depends on the element population alone (which elements
      # exist, in what order), like the document's <style>/<link> list: an
      # attribute-triggered cascade rebuild can then skip re-walking for them.
      def tree_generation
        @tree_generation || 0
      end

      def __internal_bump_style_generation__
        @style_generation = style_generation + 1
        nil
      end

      def __internal_bump_dom_generation__
        @dom_generation = dom_generation + 1
        nil
      end

      # A childList mutation: tree shape feeds both selector matching and the
      # rule -> element index, so everything is suspect.
      def __internal_note_tree_mutation__
        @tree_generation = tree_generation + 1
        __internal_bump_dom_generation__
        __internal_bump_style_generation__
      end

      # An attribute mutation: selector results are always suspect (any cached
      # query could carry an attribute selector), but the cascade only when the
      # indexed rules read this attribute — or when the attribute belongs to a
      # <style>/<link>, whose media/disabled/rel gate whole sheets.
      def __internal_note_attribute_mutation__(name, target_node)
        __internal_bump_dom_generation__
        __internal_bump_style_generation__ if __internal_style_affected_by_attribute__(name, target_node)
      end

      # A characterData mutation. Text participates in matching only through
      # `:empty` (a text node counts iff its data is non-empty), so nothing is
      # suspect unless the edit flips that emptiness — except text inside a
      # <style>, which IS the stylesheet source.
      def __internal_note_character_data_mutation__(target_node, old_value)
        # Only a Text node's data participates in :empty; a comment/PI edit
        # can't change any match. `target_node` is a backend node, so its data
        # reads through the Nokogiri-compatible #content.
        text = target_node.respond_to?(:node_type) && target_node.node_type == 3
        flipped = text && (old_value.to_s.empty? != target_node.content.to_s.empty?)
        __internal_bump_dom_generation__ if flipped
        if __internal_inside_style_element__(target_node) ||
           (flipped && __internal_style_text_sensitive__) ||
           __internal_direction_sensitive_ancestor__(target_node)
          __internal_bump_style_generation__
        end
        nil
      end

      # A form control's IDL value changed (typing, `input.value = …`, a form
      # reset). No attribute mutates, yet the value is selector-observable
      # through the validity / range / placeholder pseudo-classes, so the
      # selector epoch always moves — a cached `querySelectorAll(":invalid")`
      # would otherwise survive the very change that flipped it. The cascade
      # follows only when a sheet actually uses one of those pseudo-classes.
      def __internal_note_value_change__
        __internal_bump_dom_generation__
        if __internal_style_value_sensitive__ || __internal_direction_sensitive__
          __internal_bump_style_generation__
        end
        nil
      end

      # Selector-observable state that lives outside the attribute space
      # (focus, hover, checkedness…): both cache families are suspect.
      def __internal_note_selector_state_change__
        __internal_bump_dom_generation__
        __internal_bump_style_generation__
      end

      def __internal_style_value_sensitive__
        index = @__css_style_cache__&.index
        index ? index.value_sensitive? : true
      end

      # Whether any element's direction depends on text or a control value —
      # dir=auto, or a <bdi> (whose default is auto). Then a text or value
      # change can move a computed `direction`, so the style epoch moves too.
      # Memoized per tree generation (only a childList change adds or removes
      # such an element).
      def __internal_direction_sensitive__
        @__direction_sensitive ||= {}
        key = tree_generation
        return @__direction_sensitive[key] if @__direction_sensitive.key?(key)

        @__direction_sensitive[key] = @backend_doc.css("[dir], bdi").any? do |node|
          node.name.to_s.casecmp?("bdi") || node["dir"].to_s.strip.casecmp?("auto")
        end
      end

      # Whether `node` sits in a subtree whose direction depends on text —
      # a dir=auto or <bdi> ancestor (or itself). Unlike the document-wide
      # check, this sees a detached subtree, whose text edits still change
      # `:dir()` / `getComputedStyle().direction`.
      def __internal_direction_sensitive_ancestor__(node)
        current = node
        while current
          if current.respond_to?(:name)
            return true if current.name.to_s.casecmp?("bdi") || current["dir"].to_s.strip.casecmp?("auto")
          end
          current = current.respond_to?(:parent) ? current.parent : nil
        end
        false
      end

      def __internal_style_affected_by_attribute__(name, target_node)
        owner = target_node.respond_to?(:name) ? target_node.name.to_s.downcase : nil
        return true if owner == "style" || owner == "link"
        # The `dir` attribute drives the computed `direction` (Directionality)
        # as well as `:dir()`, neither of which is a plain attribute selector.
        return true if name.to_s.casecmp?("dir")

        index = @__css_style_cache__&.index
        # No RuleIndex yet: the bump is nearly free (at most it drops the
        # author_css?/counters memos), so stay conservative.
        return true unless index

        index.attribute_dependency?(name)
      end

      def __internal_style_text_sensitive__
        index = @__css_style_cache__&.index
        index ? index.text_sensitive? : true
      end

      def __internal_inside_style_element__(node)
        # No <style> in the document -> a text edit can't be sheet source, so
        # skip the ancestor walk. The sheet-element list is memoized per
        # tree_generation (only childList changes it), so a text-editing loop
        # between childList mutations answers this without re-walking.
        return false unless __internal_style_sheet_elements__.any? { |el| el.local_name.to_s.casecmp?("style") }

        current = node.respond_to?(:parent) ? node.parent : nil
        while current
          return true if current.respond_to?(:name) && current.name.to_s.downcase == "style"

          current = current.respond_to?(:parent) ? current.parent : nil
        end
        false
      end
    end
  end
end
