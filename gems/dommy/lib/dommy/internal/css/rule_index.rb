# frozen_string_literal: true

require_relative "parser"
require_relative "ua_stylesheet"

module Dommy
  module Internal
    module CSS
      # The document-wide "rule -> matched elements" index: every style
      # rule's selector runs through the backend's query engine exactly once,
      # so per-element cascade work is a Hash lookup. Built lazily per style
      # generation (see Cascade) and thrown away wholesale on invalidation.
      #
      # @media rules are skipped for now (their evaluation needs the viewport
      # Environment — css-cascade.md Phase 2).
      class RuleIndex
        Match = Struct.new(:origin, :specificity, :order, :declarations)

        def self.build(document)
          new(document)
        end

        def initialize(document)
          @document = document
          @index = {}.compare_by_identity
          @order = 0
          add_rules(UAStylesheet.rules, :ua)
          author_sheets.each { |rules| add_rules(rules, :author) }
        end

        EMPTY = [].freeze

        def matches_for(element)
          @index[element] || EMPTY
        end

        # True when the document carries any author CSS at all — lets
        # callers (visible? fast path) skip cascade work entirely.
        def author_rules?
          @author_rules ? true : false
        end

        private

        # Author sheets in document order. <style> contents are parsed
        # directly; <link rel=stylesheet> participates only once a host
        # environment fills its content in (not wired yet).
        def author_sheets
          @document.query_selector_all("style").to_a.map do |style_element|
            safe_parse(style_element.text_content.to_s)
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
            next unless rule.style?

            @order += 1
            @author_rules ||= origin == :author
            rule.selectors.each do |selector|
              query(selector.text).each do |element|
                (@index[element] ||= []) << Match.new(origin, selector.specificity, @order, rule.declarations)
              end
            end
          end
        end

        # Selector matching is the backend's job; selectors it can't evaluate
        # (e.g. state pseudo-classes, Phase 4) degrade to matching nothing.
        def query(selector_text)
          @document.query_selector_all(selector_text).to_a
        rescue StandardError
          EMPTY
        end
      end
    end
  end
end
