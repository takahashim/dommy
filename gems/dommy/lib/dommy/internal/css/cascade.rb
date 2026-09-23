# frozen_string_literal: true

require_relative "parser"
require_relative "property_registry"
require_relative "custom_properties"
require_relative "counters"
require_relative "renderability"
require_relative "style_cache"
require_relative "computed_style_builder"
require_relative "rule_index"
require_relative "computed_style_declaration"

module Dommy
  module Internal
    module CSS
      # The cascade's entry point and its memory (css-cascade.md P1). An
      # element's computed style comes from the UA sheet, the document's
      # <style> sheets and its style attribute; the work itself is split in
      # two — CascadedDeclarations ranks the declarations, ComputedStyleBuilder
      # turns the winners into values — and what lives here is the caching that
      # makes both affordable.
      #
      # Per-document state (RuleIndex + per-element memo) is cached against
      # Document#style_generation and rebuilt wholesale when it moves — which
      # style-neutral mutations avoid (the epoch split: see Document's
      # __internal_note_* seams and RuleIndex's dependency collection).
      #
      # Precedence, high to low: UA !important > author !important (the
      # style attribute's !important on top) > style attribute > author
      # normal (specificity, then source order) > UA normal.
      module Cascade
        module_function

        # The computed style of `element` as a frozen Hash of
        # "property" => "value" strings. Raises Parser::Unavailable when the
        # makiri-backed CSS parser is missing.
        def computed_style(element, pseudo_element: nil)
          document = element.owner_document
          return {}.freeze unless document
          # CSSOM: an element that is not rendered has no computed style —
          # browsers return empty strings for every property.
          return {}.freeze if Renderability.not_rendered?(element, method(:computed_style))

          cache = style_cache(document)
          if pseudo_element
            cache.pseudo_computed(pseudo_name(pseudo_element), element) do
              compute(element, document, pseudo_element: pseudo_element)
            end
          else
            cache.computed(element) { compute(element, document) }
          end
        end

        # Cheap per-generation gate used by visibility checks: does the
        # document carry any author CSS at all? When it doesn't (and for
        # makiri-less installs), the HTML-level fast path is already exact
        # and no RuleIndex needs building.
        def author_css?(document)
          return false unless document && Parser.available?

          cache = style_cache(document)
          cache.author_css = document_has_author_css?(document) if cache.author_css.nil?
          cache.author_css
        end

        # Any <style>, or a <link rel=stylesheet> a host has filled in (an
        # unfilled link contributes nothing, so it stays off the slow path).
        def document_has_author_css?(document)
          return true unless document.query_selector("style").nil?

          document.query_selector_all("link").any? do |link|
            link.respond_to?(:__internal_stylesheet_for_cascade__) && link.__internal_stylesheet_for_cascade__
          end
        end

        def style_cache(document)
          cache = document.__css_style_cache__
          unless cache&.current?(document.style_generation)
            cache = StyleCache.new(document.style_generation)
            document.__css_style_cache__ = cache
          end
          cache
        end

        # The RuleIndex is built lazily so author_css? (and sheetless
        # documents in general) never pay for UA-sheet selector queries.
        def index_for(document)
          cache = style_cache(document)
          cache.index ||= RuleIndex.build(document)
        end

        # The in-scope CSS counter values at `element` ({ name => stack }), for
        # resolving counter()/counters() in generated content. The whole-document
        # map is built once per style generation. {} when there is no CSS layer.
        def counter_values(element)
          document = element.respond_to?(:owner_document) ? element.owner_document : nil
          return {} unless document && Parser.available?

          map = style_cache(document).counters || build_counters(document)
          map[element] || {}
        end

        # Walk the document's counters and memoize them. The cache is fetched
        # again after the walk rather than assigned into the one we looked in:
        # building reads computed styles, each of which goes through
        # style_cache, so were the generation to move mid-walk the entry would
        # otherwise land in a hash nobody reads again.
        def build_counters(document)
          map = Counters.build(document, ->(element) { computed_style(element) })
          style_cache(document).counters = map
        end

        # The computed style itself is ComputedStyleBuilder's; this module owns
        # the caches that make its parent/root lookups cheap.
        def compute(element, document, pseudo_element: nil)
          ComputedStyleBuilder.new(element, document, index_for(document), method(:computed_style),
            pseudo_element: pseudo_element).build
        end

        def pseudo_name(pseudo_element)
          pseudo_element.to_s.delete_prefix("::").delete_prefix(":")
        end
      end
    end
  end
end
