# frozen_string_literal: true

require_relative "directionality"

module Dommy
  module Internal
    # The counters the caches hang on: one for the tree's shape, one for what
    # a selector can match, one for what the cascade computes. A mutation bumps
    # the ones it can actually invalidate, which is the whole point — a text
    # edit inside a <p> must not throw away the rule index.
    #
    # Each is the sum of the document's own count, which its mutation paths
    # move, and Makiri's count of the matching edits — tree_version for the
    # child lists, attribute_version for the attributes — which moves however
    # the backend was edited. Every term only grows, so the sum changes with
    # any of them: an edit that reached Makiri without passing through the
    # document's paths still retires what hangs on the counter. Makiri counts
    # no character-data edit, so a text edit that flips nothing moves nothing
    # here either; one that flips `:empty` is seen through the document's
    # own path alone.
    #
    # Host contract: @backend_doc, @__internal_css_style_cache__,
    # #__internal_style_sheet_elements__ and #quirks_mode?.
    module DocumentGenerations
      # The attributes SelectorIndex records an element under.
      INDEXED_ATTRIBUTES = %w[id class].freeze

      def style_generation
        (@style_generation || 0) + backend_tree_version
      end

      def dom_generation
        (@dom_generation || 0) + backend_tree_version + backend_attribute_version
      end

      # Moves only on childList mutations — the coarsest epoch. Keys memos
      # whose value depends on the element population alone (which elements
      # exist, in what order), like the document's <style>/<link> list: an
      # attribute-triggered cascade rebuild can then skip re-walking for them.
      def tree_generation
        (@tree_generation || 0) + backend_tree_version
      end

      # What the selector index (SelectorIndex) is built from: the element tree
      # and each element's `id` and `class`. Nothing else it holds can go
      # stale, so a value, focus or `data-*` change, which moves
      # dom_generation, leaves it standing.
      #
      # An attribute edit the document saw and could name (see
      # #__internal_note_attribute_mutation__) is accounted for: an `id` or
      # `class` one moves the index's own counter, any other moves nothing.
      # One Makiri counted that the document did not account for — edited
      # around its mutation paths — moves the epoch, so the index is rebuilt
      # rather than trusted.
      def __internal_selector_index_generation__
        version = backend_attribute_version
        unless version == @__index_attribute_version
          @__index_attribute_epoch = (@__index_attribute_epoch || 0) + 1
          @__index_attribute_version = version
        end
        [tree_generation, @__index_generation || 0, @__index_attribute_epoch, quirks_mode?]
      end

      def __internal_bump_style_generation__
        @style_generation = (@style_generation || 0) + 1
        # Whatever changed may have made the focused element unfocusable:
        # the next rendering update's focus fixup checks.
        __internal_schedule_rendering_update__ if @active_element
        nil
      end

      def __internal_bump_dom_generation__
        @dom_generation = (@dom_generation || 0) + 1
        __internal_schedule_rendering_update__ if @active_element
        nil
      end

      # A childList mutation: tree shape feeds both selector matching and the
      # rule -> element index, so everything is suspect.
      def __internal_note_tree_mutation__
        @tree_generation = (@tree_generation || 0) + 1
        __internal_bump_dom_generation__
        __internal_bump_style_generation__
      end

      # An attribute mutation: selector results are always suspect (any cached
      # query could carry an attribute selector), but the cascade only when the
      # indexed rules read this attribute — or when the attribute belongs to a
      # <style>/<link>, whose media/disabled/rel gate whole sheets.
      def __internal_note_attribute_mutation__(name, target_node)
        __internal_bump_dom_generation__
        __internal_note_index_attribute__(name)
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
        text = target_node.node_type == 3
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
        index = @__internal_css_style_cache__&.index
        index ? index.value_sensitive? : true
      end

      # Whether any element's direction depends on text or a control value
      # (Directionality.text_dependent?). Then a text or value change can move
      # a computed `direction`, so the style epoch moves too. Memoized for the
      # current tree generation (only a childList change adds or removes such
      # an element).
      def __internal_direction_sensitive__
        generation = tree_generation
        return @__direction_sensitive[1] if @__direction_sensitive&.first == generation

        sensitive = @backend_doc.css("[dir], bdi").any? do |node|
          Directionality.text_dependent?(node.name, Backend.no_namespace_attribute_value(node, "dir"))
        end
        @__direction_sensitive = [generation, sensitive]
        sensitive
      end

      # Whether `node` sits in a subtree whose direction depends on text — a
      # text-dependent ancestor (or itself). Unlike the document-wide check,
      # this sees a detached subtree, whose text edits still change `:dir()` /
      # `getComputedStyle().direction`.
      def __internal_direction_sensitive_ancestor__(node)
        current = node
        while current
          if current.element? &&
             Directionality.text_dependent?(current.name, Backend.no_namespace_attribute_value(current, "dir"))
            return true
          end

          current = current.parent
        end
        false
      end

      def __internal_style_affected_by_attribute__(name, target_node)
        owner = target_node.name.to_s.downcase
        return true if owner == "style" || owner == "link"
        # The `dir` attribute drives the computed `direction` (Directionality)
        # as well as `:dir()`, neither of which is a plain attribute selector.
        return true if name.to_s.casecmp?("dir")
        # The UA rules for popovers and dialogs (UAStylesheet
        # .top_layer_declarations) read these with no selector of their own.
        return true if name.to_s.casecmp?("popover") || name.to_s.casecmp?("open")

        index = @__internal_css_style_cache__&.index
        # No RuleIndex yet: the bump is nearly free (at most it drops the
        # author_css?/counters memos), so stay conservative.
        return true unless index

        index.attribute_dependency?(name)
      end

      def __internal_style_text_sensitive__
        index = @__internal_css_style_cache__&.index
        index ? index.text_sensitive? : true
      end

      def __internal_inside_style_element__(node)
        # No <style> in the document -> a text edit can't be sheet source, so
        # skip the ancestor walk. The sheet-element list is memoized per
        # tree_generation (only childList changes it), so a text-editing loop
        # between childList mutations answers this without re-walking.
        return false unless __internal_style_sheet_elements__.any? { |el| el.local_name.to_s.casecmp?("style") }

        current = node.parent
        while current
          return true if current.name.to_s.downcase == "style"

          current = current.parent
        end
        false
      end

      private

      # The index-side accounting for one attribute edit, called after the
      # backend took it. A non-indexed name is accounted only when it is the
      # single backend edit since the last accounted one; anything else leaves
      # the gap for #__internal_selector_index_generation__ to see.
      def __internal_note_index_attribute__(name)
        if INDEXED_ATTRIBUTES.any? { |indexed| name.casecmp?(indexed) }
          @__index_generation = (@__index_generation || 0) + 1
        else
          version = backend_attribute_version
          @__index_attribute_version = version if @__index_attribute_version == version - 1
        end
      end

      def backend_tree_version = @backend_doc ? @backend_doc.tree_version : 0

      def backend_attribute_version = @backend_doc ? @backend_doc.attribute_version : 0
    end
  end
end
