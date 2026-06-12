# frozen_string_literal: true

require_relative "parser"
require_relative "media_query"
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
        Match = Struct.new(:origin, :specificity, :order, :declarations)

        def self.build(document)
          new(document)
        end

        def initialize(document)
          @document = document
          @index = {}.compare_by_identity
          @pseudo_index = Hash.new { |h, k| h[k] = {}.compare_by_identity }
          @order = 0
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

        private

        # Author sheets in document order. <style> contents are parsed
        # directly; a media attribute gates the whole sheet (same evaluator
        # as @media). When a CSSStyleSheet was instantiated for the element
        # (and isn't stale), its CSSOM state wins: `cascade_text` carries
        # insertRule/deleteRule edits and `disabled` mutes the whole sheet.
        # <link rel=stylesheet> participates only once a host environment
        # fills its content in (not wired yet).
        def author_sheets
          @document.query_selector_all("style").to_a.filter_map do |style_element|
            media = style_element.get_attribute("media").to_s.strip
            next nil unless media.empty? || MediaQuery.match?(media, environment)

            sheet = style_element.respond_to?(:__instantiated_sheet__) && style_element.__instantiated_sheet__
            if sheet
              next nil if sheet.disabled

              safe_parse(sheet.cascade_text)
            else
              safe_parse(style_element.text_content.to_s)
            end
          end
        end

        def safe_parse(text)
          Parser.parse(text)
        rescue Parser::Unavailable
          raise
        rescue StandardError
          []
        end

        def add_rules(rules, origin)
          rules.each do |rule|
            if rule.media?
              # Nested @media is an AND: each level's condition gates its
              # contents. Inactive blocks contribute nothing to the index.
              add_rules(rule.rules, origin) if MediaQuery.match?(rule.condition, environment)
              next
            end

            @order += 1
            @author_rules ||= origin == :author
            rule.selectors.each do |selector|
              # Classify per complex selector, not per list — `div, ::before`
              # must index its branches separately (element vs pseudo).
              selector.ast.selectors.each do |complex|
                pseudo = complex.pseudo_element&.name
                target_index = pseudo ? @pseudo_index[pseudo] : @index
                query_complex(complex).each do |element|
                  (target_index[element] ||= []) << Match.new(origin, complex.specificity.to_a, @order, rule.declarations)
                end
              end
            end
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
