# frozen_string_literal: true

require_relative "../selector_parser"

module Dommy
  module Internal
    module CSS
      # The abstraction seam over the CSS stylesheet parser. The only
      # implementation is makiri's lexbor binding
      # (Makiri::Lexbor::CSS.parse_stylesheet) — see css-cascade.md: the
      # tokenizer, error recovery, and specificity all come from lexbor;
      # this module just normalizes its plain-Hash output into structs the
      # cascade layer consumes. CSS parsing is independent of the DOM
      # backend, so this works on the Nokogiri backend too as long as the
      # makiri gem is installed.
      module Parser
        # One comma branch of a selector list. `specificity` is the
        # Selectors L4 [A, B, C] triple computed from Dommy's AST.
        Selector = Struct.new(:text, :ast, :specificity)

        Declaration = Struct.new(:name, :value, :important)

        StyleRule = Struct.new(:selectors, :declarations) do
          def grouping? = false
        end

        # Grouping at-rules (CSS conditional rules): their block contributes
        # its rules to the cascade only when the rule is "active" (RuleIndex
        # decides — @media query matches, @supports condition holds, @layer
        # always). The block is flattened in source order; @layer ordering and
        # @supports/@media precedence beyond source order are out of scope.
        MediaRule = Struct.new(:condition, :rules) do
          def grouping? = true
        end

        # @layer { ... } — treated as plain source order (its rules always
        # participate; layer precedence is a documented non-goal).
        LayerRule = Struct.new(:rules) do
          def grouping? = true
        end

        # @supports (cond) { ... } — its rules participate when `condition`
        # evaluates true (Supports.match?).
        SupportsRule = Struct.new(:condition, :rules) do
          def grouping? = true
        end

        # Raised when CSS features are used without the makiri gem.
        class Unavailable < StandardError
          def initialize(msg = nil)
            super(msg || "Dommy's CSS support requires the 'makiri' gem (its bundled " \
                         "lexbor provides the CSS parser). Add `gem \"makiri\"` to use " \
                         "stylesheet-aware computed styles.")
          end
        end

        module_function

        def available?
          return @available unless @available.nil?

          @available = begin
            require "makiri"
            !!defined?(::Makiri::Lexbor::CSS)
          rescue LoadError
            false
          end
        end

        # Parse a stylesheet into an Array of StyleRule / MediaRule / LayerRule
        # / SupportsRule in source order (other at-rules are ignored). Lexbor's
        # css-syntax-3 error recovery applies; selectors and at-rules it can't
        # parse are surfaced for Dommy to re-validate, not silently dropped.
        def parse(text)
          raise Unavailable unless available?

          normalize_rules(::Makiri::Lexbor::CSS.parse_stylesheet(text.to_s))
        end

        def normalize_rules(rules)
          rules.filter_map do |rule|
            case rule[:type]
            when :style
              build_style_rule(normalize_selectors(rule[:selectors]), rule[:declarations])
            when :bad_style
              # lexbor couldn't parse this selector list (most often a
              # pseudo-element like ::before, which its parser predates).
              # Re-validate the raw prelude with Dommy's Selectors L4 parser:
              # pseudo-element rules survive, genuinely invalid ones drop
              # (normalize_selectors returns []).
              build_style_rule(normalize_selectors([{text: rule[:selector_text]}]), rule[:declarations])
            when :at_rule
              normalize_at_rule(rule)
            end
          end
        end

        # @media / @layer / @supports become grouping rules the cascade
        # understands; every other at-rule (@font-face, @keyframes, @import,
        # @page, ...) is ignored for now (returning nil drops it from the
        # rule stream, but lexbor still parsed it, so nothing crashes).
        def normalize_at_rule(rule)
          case rule[:name].to_s.downcase
          when "media"
            MediaRule.new(rule[:prelude], normalize_rules(rule[:rules]))
          when "layer"
            LayerRule.new(normalize_rules(rule[:rules]))
          when "supports"
            SupportsRule.new(rule[:prelude], normalize_rules(rule[:rules]))
          end
        end

        def build_style_rule(selectors, declarations)
          return nil if selectors.empty?

          StyleRule.new(selectors, declarations.map { |d| Declaration.new(d[:name], d[:value], d[:important]) })
        end

        def normalize_selectors(selectors)
          selectors.map do |selector|
            ast = Internal::SelectorParser.parse!(selector[:text])
            Selector.new(selector[:text], ast, ast.specificity.to_a)
          end
        rescue DOMException::SyntaxError
          []
        end

        # Parse a bare declaration block (no selector / braces) into
        # Declarations. Used by the CSSOM RuleStyleDeclaration to read a rule's
        # `style`; the cascade reaches declarations through parse/normalize_rules.
        def parse_declarations(text)
          text.split(";").filter_map do |chunk|
            name, value = chunk.split(":", 2)
            next unless name && value

            name = name.strip.downcase
            value = value.strip
            next if name.empty? || value.empty?

            important = !value.sub!(/\s*!important\s*\z/i, "").nil?
            Declaration.new(name, value.strip, important)
          end
        end
      end
    end
  end
end
