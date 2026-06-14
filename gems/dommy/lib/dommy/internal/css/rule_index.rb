# frozen_string_literal: true

require_relative "parser"
require_relative "media_query"
require_relative "supports"
require_relative "ua_stylesheet"
require_relative "../selector_ast"
require_relative "../selector_matcher"

module Dommy
  module Internal
    module CSS
      # The document-wide "rule -> matched elements" index: every style
      # rule's selector runs through SelectorMatcher exactly once, so
      # per-element cascade work is a Hash lookup. Built lazily per style
      # generation (see Cascade) and thrown away wholesale on invalidation —
      # a viewport resize bumps the generation too, so @media re-evaluates.
      class RuleIndex
        Match = Struct.new(:origin, :specificity, :order, :declarations, :layer)

        def self.build(document)
          new(document)
        end

        def initialize(document)
          @document = document
          @index = {}.compare_by_identity
          @pseudo_index = Hash.new { |h, k| h[k] = {}.compare_by_identity }
          @order = 0
          @imported_urls = {}
          # Cascade-layer order: full layer name => 0-based index, assigned on
          # first declaration (statement or block), in source order across all
          # sheets. Unlayered styles act as a final implicit layer at index
          # #layer_count (see Cascade#layer_rank).
          @layer_order = {}
          @anon_layer_seq = 0
          add_rules(UAStylesheet.rules, :ua)
          author_sheets.each { |rules| add_rules(rules, :author) }
        end

        EMPTY = [].freeze

        def matches_for(element, pseudo_element = nil)
          if pseudo_element
            (@pseudo_index[pseudo_name(pseudo_element)] || EMPTY)[element] || EMPTY
          else
            @index[element] || EMPTY
          end
        end

        # True when the document carries any author CSS at all — lets
        # callers (visible? fast path) skip cascade work entirely.
        def author_rules?
          @author_rules ? true : false
        end

        # The number of explicit cascade layers — also the index of the
        # implicit final layer that holds all unlayered styles.
        def layer_count
          @layer_order.size
        end

        # A match's layer position for cascade sorting: the explicit layer's
        # 0-based order, or #layer_count for unlayered styles (and any layer
        # name that was never declared). See Cascade#layer_rank.
        def layer_index_of(layer)
          (layer && @layer_order[layer]) || @layer_order.size
        end

        private

        # Author sheets in document order. <style> and <link rel=stylesheet>
        # are walked together so their relative order is preserved (it breaks
        # cascade ties). A `media` attribute gates the whole sheet (same
        # evaluator as @media); `disabled` mutes it.
        def author_sheets
          @document.query_selector_all("style, link").to_a.filter_map do |element|
            media = element.get_attribute("media").to_s.strip
            next nil unless media.empty? || MediaQuery.match?(media, environment)

            link_element?(element) ? link_sheet_rules(element) : style_element_rules(element)
          end
        end

        def link_element?(element)
          element.local_name.to_s.casecmp("link").zero?
        end

        # A <link rel=stylesheet> contributes only once a host environment has
        # filled its CSS in (Dommy fetches nothing). The filled sheet is read
        # through `cascade_text`, exactly like a <style>'s CSSOM sheet.
        def link_sheet_rules(element)
          return nil unless element.respond_to?(:__internal_stylesheet_for_cascade__)

          sheet = element.__internal_stylesheet_for_cascade__
          return nil if sheet.nil? || sheet.disabled

          safe_parse(sheet.cascade_text)
        end

        # When a CSSStyleSheet was instantiated for the <style> (and isn't
        # stale), its CSSOM state wins: `cascade_text` carries insertRule edits
        # and `disabled` mutes it. Otherwise the element's text is parsed.
        def style_element_rules(element)
          sheet = element.respond_to?(:__internal_instantiated_sheet__) && element.__internal_instantiated_sheet__
          if sheet
            return nil if sheet.disabled

            safe_parse(sheet.cascade_text)
          else
            safe_parse(element.text_content.to_s)
          end
        end

        def safe_parse(text)
          Parser.parse(text)
        rescue Parser::Unavailable
          raise
        rescue StandardError
          []
        end

        def add_rules(rules, origin, layer: nil)
          rules.each do |rule|
            case rule
            when Parser::ImportRule
              import_rules(rule, origin, layer: layer)
            when Parser::LayerStatement
              # `@layer a, b;` only fixes layer order; no rules to add.
              rule.names.each { |name| register_layer(layer_full_name(layer, name)) }
            when Parser::LayerRule
              # `@layer name { ... }` — enter the (possibly nested) layer.
              full = layer_full_name(layer, rule.name)
              register_layer(full)
              add_rules(rule.rules, origin, layer: full)
            else
              if rule.grouping?
                # @media / @supports: the block contributes (flattened, in
                # source order, keeping the current layer) only when active.
                add_rules(rule.rules, origin, layer: layer) if grouping_active?(rule)
              else
                add_style_rule(rule, origin, layer)
              end
            end
          end
        end

        def add_style_rule(rule, origin, layer)
          @order += 1
          @author_rules ||= origin == :author
          rule.selectors.each do |selector|
            # Classify per complex selector, not per list — `div, ::before`
            # must index its branches separately (element vs pseudo).
            selector.ast.selectors.each do |complex|
              pseudo = complex.pseudo_element&.name
              target_index = pseudo ? @pseudo_index[pseudo] : @index
              query_complex(complex).each do |element|
                (target_index[element] ||= []) << Match.new(origin, complex.specificity.to_a, @order, rule.declarations, layer)
              end
            end
          end
        end

        # Record a (fully-qualified) layer's first appearance, idempotently —
        # registering each ancestor prefix first so a parent layer always
        # precedes its sublayers in layer order (`@layer a.b` declares `a` too,
        # and earlier). Returns the name.
        def register_layer(name)
          parts = name.split(".")
          parts.each_index do |i|
            prefix = parts[0..i].join(".")
            @layer_order[prefix] ||= @layer_order.size
          end
          name
        end

        # The full dotted name of layer `name` nested under `parent` (`outer` +
        # `inner` -> `outer.inner`). A nil `name` is anonymous — minted unique
        # each call so it can never be reopened (the leading space keeps it out
        # of any real ident space).
        def layer_full_name(parent, name)
          if name.nil?
            @anon_layer_seq += 1
            name = " anon#{@anon_layer_seq}"
          end

          parent ? "#{parent}.#{name}" : name
        end

        # Splice an @import's referenced sheet in at this position: gate on its
        # media query, resolve the URL through the host (Dommy fetches nothing),
        # then parse and recurse. Each URL is imported once per build — a cheap
        # cycle/duplicate guard.
        def import_rules(rule, origin, layer: nil)
          return unless rule.media.empty? || MediaQuery.match?(rule.media, environment)
          return if @imported_urls[rule.url]

          @imported_urls[rule.url] = true
          css = resolve_import(rule.url)
          add_rules(safe_parse(css), origin, layer: layer) if css
        end

        # The host's URL -> CSS resolver (dommy-rack wires it to a same-origin
        # fetch); nil when no host supplied one, so @import then contributes
        # nothing.
        def resolve_import(url)
          resolver = @document.respond_to?(:css_import_resolver) && @document.css_import_resolver
          return nil unless resolver

          text = resolver.call(url)
          text&.to_s
        rescue StandardError
          nil
        end

        # Whether a grouping rule's block applies: @media gates on the viewport
        # environment, @supports on its condition. (@layer is handled in
        # add_rules, not here.) Unknown grouping kinds default to active.
        def grouping_active?(rule)
          case rule
          when Parser::MediaRule then MediaQuery.match?(rule.condition, environment)
          when Parser::SupportsRule then Supports.match?(rule.condition)
          else true
          end
        end

        # The media environment of the document's window — or the default
        # (1280x720) for windowless documents (fragments, DOMParser output).
        def environment
          @environment ||= begin
            view = @document.respond_to?(:default_view) ? @document.default_view : nil
            (view && view.media_environment) || MediaQuery::DEFAULT
          end
        end

        # Match one complex selector (its pseudo-element stripped — the
        # matcher never matches pseudo-element subjects against elements;
        # specificity stays that of the full selector).
        def query_complex(complex)
          complex = complex.without_pseudo_element if complex.pseudo_element?
          list = Internal::SelectorAST::SelectorList.new([complex])
          Internal::SelectorMatcher.query(@document, list)
        end

        def pseudo_name(pseudo_element)
          pseudo_element.to_s.delete_prefix("::").delete_prefix(":")
        end
      end
    end
  end
end
