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
        Match = Struct.new(:origin, :specificity, :order, :declarations, :layer, :proximity)

        # A resolved @scope: the scoping roots that scope-start matched, and the
        # per-root scope limits (boundary elements from scope-end). An element is
        # in scope for a root when it is an inclusive descendant of that root and
        # not an inclusive descendant of any of the root's limits.
        Scope = Struct.new(:roots, :ends)

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
          add_shadow_sheets
        end

        EMPTY = [].freeze

        # A shadow-tree styling context: the ShadowRoot whose <style> a rule came
        # from, and its host element (what `:host` targets).
        Shadow = Struct.new(:root, :host)

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

        def add_rules(rules, origin, layer: nil, scope: nil, shadow: nil)
          rules.each do |rule|
            case rule
            when Parser::ImportRule
              import_rules(rule, origin, layer: layer, scope: scope)
            when Parser::LayerStatement
              # `@layer a, b;` only fixes layer order; no rules to add.
              rule.names.each { |name| register_layer(layer_full_name(layer, name)) }
            when Parser::LayerRule
              # `@layer name { ... }` — enter the (possibly nested) layer.
              full = layer_full_name(layer, rule.name)
              register_layer(full)
              add_rules(rule.rules, origin, layer: full, scope: scope, shadow: shadow)
            when Parser::ScopeRule
              # `@scope (start) to (end) { ... }` — resolve the roots/limits and
              # scope the block's rules. (A nested @scope replaces the outer one
              # for its block; combining both is a documented limitation.)
              resolved = build_scope(rule.start, rule.end)
              add_rules(rule.rules, origin, layer: layer, scope: resolved, shadow: shadow) if resolved
            else
              if rule.grouping?
                # @media / @supports: the block contributes (flattened, in
                # source order, keeping the current layer/scope/shadow) only when active.
                add_rules(rule.rules, origin, layer: layer, scope: scope, shadow: shadow) if grouping_active?(rule)
              else
                add_style_rule(rule, origin, layer, scope, shadow)
              end
            end
          end
        end

        def add_style_rule(rule, origin, layer, scope, shadow)
          @order += 1
          @author_rules ||= origin == :author
          rule.selectors.each do |selector|
            # Classify per complex selector, not per list — `div, ::before`
            # must index its branches separately (element vs pseudo).
            selector.ast.selectors.each do |complex|
              spec = complex.specificity.to_a
              if shadow
                index_shadow_complex(complex, spec, origin, layer, shadow, rule.declarations)
              elsif complex.pseudo_element&.name == "part"
                index_part_complex(complex, spec, origin, layer, rule.declarations)
              else
                pseudo = complex.pseudo_element&.name
                target_index = pseudo ? @pseudo_index[pseudo] : @index
                if scope
                  index_scoped(complex, spec, target_index, origin, layer, scope, rule.declarations)
                else
                  query_complex(complex).each do |element|
                    (target_index[element] ||= []) << Match.new(origin, spec, @order, rule.declarations, layer, nil)
                  end
                end
              end
            end
          end
        end

        # Each ShadowRoot's <style> sheets, scoped to that shadow tree. Document
        # queries never cross into a shadow fragment, so a shadow tree's elements
        # otherwise get no author rules — this is where encapsulated styles enter.
        def add_shadow_sheets
          return unless @document.respond_to?(:__internal_all_shadow_roots__)

          @document.__internal_all_shadow_roots__.each do |root|
            host = root.respond_to?(:host) ? root.host : nil
            next unless host

            shadow = Shadow.new(root, host)
            shadow_style_rules(root).each { |rules| add_rules(rules, :author, shadow: shadow) }
          end
        end

        def shadow_style_rules(root)
          root.query_selector_all("style").to_a.filter_map { |style| safe_parse(style.text_content.to_s) }
        end

        # Index one complex selector of a shadow-tree style rule. Handles the
        # shadow-only pseudos (`:host` / `:host()` targeting the host, and
        # `::slotted()` targeting assigned light-DOM nodes) and scopes plain
        # selectors to the shadow tree.
        def index_shadow_complex(complex, spec, origin, layer, shadow, declarations)
          if complex.pseudo_element&.name == "slotted"
            slotted_targets(complex, shadow).each { |el| record(@index, el, origin, spec, declarations, layer) }
            return
          end

          pseudo = complex.pseudo_element&.name
          target_index = pseudo ? @pseudo_index[pseudo] : @index
          shadow_targets(complex, shadow).each { |el| record(target_index, el, origin, spec, declarations, layer) }
        end

        # The elements a shadow-internal complex selector matches. A leading
        # `:host` / `:host()` targets the host (when it is the whole selector) or
        # acts as the scoping ancestor for the shadow-tree subject of the rest of
        # the selector; otherwise the selector is matched within the shadow tree.
        def shadow_targets(complex, shadow)
          host_pseudo = leading_host_pseudo(complex)
          unless host_pseudo
            list = single_complex_list(complex.pseudo_element? ? complex.without_pseudo_element : complex)
            return Internal::SelectorMatcher.query(shadow.root, list, scope: shadow.root)
          end

          return [] unless host_matches?(shadow.host, host_pseudo)
          return [shadow.host] if complex.parts.length == 1

          # `:host(...) <rest>` — every shadow element is conceptually a descendant
          # of the host, so the remainder matches within the shadow tree. (The
          # combinator after :host is treated as descendant; child/sibling refinement
          # is a documented limitation.)
          Internal::SelectorMatcher.query(shadow.root, host_remainder_list(complex), scope: shadow.root)
        end

        def leading_host_pseudo(complex)
          complex.parts.first.compound.subclass_selectors.find do |selector|
            selector.is_a?(Internal::SelectorAST::PseudoClass) && %w[host host-context].include?(selector.name)
          end
        end

        # Whether `:host` / `:host(arg)` / `:host-context(arg)` matches the host.
        def host_matches?(host, host_pseudo)
          return false unless host

          argument = host_pseudo.argument
          if host_pseudo.name == "host-context"
            return false if argument.nil?

            return host_or_ancestor_matches?(host, argument)
          end
          argument.nil? || Internal::SelectorMatcher.matches?(host, argument)
        end

        def host_or_ancestor_matches?(element, argument)
          current = element
          while current.respond_to?(:parent_element)
            return true if Internal::SelectorMatcher.matches?(current, argument)

            current = current.parent_element
          end
          false
        end

        # Drop the leading `:host(...)` part, returning the remaining complex as a
        # one-selector list (its new head loses the inherited combinator).
        def host_remainder_list(complex)
          rest = complex.parts[1..]
          parts = [Internal::SelectorAST::Part.new(nil, rest.first.compound)] + rest[1..]
          single_complex_list(Internal::SelectorAST::ComplexSelector.new(parts))
        end

        # `::slotted(<compound>)` — the light-DOM nodes assigned to a slot in this
        # shadow tree whose flat-tree parent is the host, matching the compound.
        def slotted_targets(complex, shadow)
          compound = complex.pseudo_element.argument
          list = compound.is_a?(Internal::SelectorAST::SelectorList) ? compound : single_complex_list(compound)
          assigned_slottables(shadow).select { |el| Internal::SelectorMatcher.matches?(el, list) }
        end

        def assigned_slottables(shadow)
          shadow.root.query_selector_all("slot").to_a.flat_map do |slot|
            slot.respond_to?(:assigned_elements) ? slot.assigned_elements : []
          end
        end

        # `<compound>::part(name)` from a document/outer style: the elements with a
        # matching `part` token inside the shadow tree of a host the compound chain
        # matches.
        def index_part_complex(complex, spec, origin, layer, declarations)
          names = complex.pseudo_element.argument
          return unless names.is_a?(Array) && !names.empty?

          host_list = single_complex_list(complex.without_pseudo_element)
          Internal::SelectorMatcher.query(@document, host_list).each do |host|
            part_elements(host, names).each { |el| record(@index, el, origin, spec, declarations, layer) }
          end
        end

        def part_elements(host, names)
          root = host.respond_to?(:shadow_root) ? host.shadow_root : nil
          return [] unless root

          root.query_selector_all("[part]").to_a.select do |el|
            tokens = el.get_attribute("part").to_s.split(/\s+/)
            names.all? { |name| tokens.include?(name) }
          end
        end

        def single_complex_list(complex)
          Internal::SelectorAST::SelectorList.new([complex])
        end

        def record(target_index, element, origin, spec, declarations, layer)
          (target_index[element] ||= []) << Match.new(origin, spec, @order, declarations, layer, nil)
        end

        # Index a scoped style rule: for each scoping root, match the selector
        # with `:scope` bound to that root, keep only in-scope subjects, and tag
        # each match with its scope proximity (generations from the subject up to
        # the root — the cascade's nearest-scope tiebreaker).
        def index_scoped(complex, spec, target_index, origin, layer, scope, declarations)
          scope.roots.each do |root|
            ends = scope.ends[root] || EMPTY
            query_complex(complex, scope: root).each do |element|
              next unless in_scope?(element, root, ends)

              (target_index[element] ||= []) <<
                Match.new(origin, spec, @order, declarations, layer, generations(element, root))
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
        def import_rules(rule, origin, layer: nil, scope: nil)
          return unless rule.media.empty? || MediaQuery.match?(rule.media, environment)
          return if @imported_urls[rule.url]

          @imported_urls[rule.url] = true
          css = resolve_import(rule.url)
          add_rules(safe_parse(css), origin, layer: layer, scope: scope) if css
        end

        # Resolve an @scope's prelude into a Scope (roots + per-root limits), or
        # nil when the scope-start selector is invalid (the block then matches
        # nothing). A nil start scopes to the document element; a nil end has no
        # lower boundary. scope-end is matched with `:scope` bound to the root
        # and kept to that root's subtree (a "donut" lower boundary).
        def build_scope(start_text, end_text)
          roots =
            if start_text
              ast = parse_selector(start_text)
              return nil unless ast

              Internal::SelectorMatcher.query(@document, ast)
            else
              [@document.document_element].compact
            end

          end_ast = end_text ? parse_selector(end_text) : nil
          ends = {}.compare_by_identity
          roots.each do |root|
            ends[root] = if end_ast
              Internal::SelectorMatcher.query(@document, end_ast, scope: root).select { |limit| inclusive?(root, limit) }
            else
              EMPTY
            end
          end
          Scope.new(roots, ends)
        end

        def parse_selector(text)
          Internal::SelectorParser.parse!(text)
        rescue DOMException::SyntaxError
          nil
        end

        # In scope for `root`: an inclusive descendant of the root that is not an
        # inclusive descendant of any of the root's scope limits.
        def in_scope?(element, root, ends)
          return false unless inclusive?(root, element)

          ends.none? { |limit| inclusive?(limit, element) }
        end

        # Whether `descendant` is `ancestor` or contained by it (DOM contains? is
        # inclusive, but the equal? guard keeps it correct for any backend).
        def inclusive?(ancestor, descendant)
          ancestor.equal?(descendant) ||
            (ancestor.respond_to?(:contains?) && ancestor.contains?(descendant))
        end

        # Scope proximity: the number of generations from `element` up to `root`
        # (0 when they are the same element). `root` is guaranteed to be an
        # ancestor-or-self of `element` (in_scope? checked it).
        def generations(element, root)
          steps = 0
          current = element
          until current.nil? || current.equal?(root)
            current = current.parent_element
            steps += 1
          end
          steps
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
        def query_complex(complex, scope: nil)
          complex = complex.without_pseudo_element if complex.pseudo_element?
          list = Internal::SelectorAST::SelectorList.new([complex])
          Internal::SelectorMatcher.query(@document, list, scope: scope)
        end

        def pseudo_name(pseudo_element)
          pseudo_element.to_s.delete_prefix("::").delete_prefix(":")
        end
      end
    end
  end
end
