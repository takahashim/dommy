# frozen_string_literal: true

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
        # Selectors L4 [A, B, C] triple computed by lexbor.
        Selector = Struct.new(:text, :specificity)

        Declaration = Struct.new(:name, :value, :important)

        StyleRule = Struct.new(:selectors, :declarations) do
          def style? = true
          def media? = false
        end

        MediaRule = Struct.new(:condition, :rules) do
          def style? = false
          def media? = true
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

        # Parse a stylesheet into an Array of StyleRule / MediaRule in source
        # order. Lexbor's css-syntax-3 error recovery applies: invalid
        # declarations and unknown at-rules are already dropped.
        def parse(text)
          raise Unavailable unless available?

          normalize_rules(::Makiri::Lexbor::CSS.parse_stylesheet(text.to_s))
        end

        def normalize_rules(rules)
          rules.filter_map do |rule|
            case rule[:type]
            when :style
              StyleRule.new(
                rule[:selectors].map { |s| Selector.new(s[:text], s[:specificity]) },
                rule[:declarations].map { |d| Declaration.new(d[:name], d[:value], d[:important]) }
              )
            when :media
              MediaRule.new(rule[:condition], normalize_rules(rule[:rules]))
            end
          end
        end
      end
    end
  end
end
