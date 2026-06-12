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

          source = text.to_s
          normalize_rules(::Makiri::Lexbor::CSS.parse_stylesheet(source)) + parse_pseudo_element_rules(source)
        end

        def normalize_rules(rules)
          rules.filter_map do |rule|
            case rule[:type]
            when :style
              selectors = normalize_selectors(rule[:selectors])
              next if selectors.empty?

              StyleRule.new(
                selectors,
                rule[:declarations].map { |d| Declaration.new(d[:name], d[:value], d[:important]) }
              )
            when :media
              MediaRule.new(rule[:condition], normalize_rules(rule[:rules]))
            end
          end
        end

        def normalize_selectors(selectors)
          selectors.map do |selector|
            ast = Internal::SelectorParser.parse!(selector[:text])
            Selector.new(selector[:text], ast, ast.specificity.to_a)
          end
        rescue DOMException::SyntaxError
          []
        end

        def parse_pseudo_element_rules(source)
          each_style_block(source).filter_map do |selector_text, declaration_text|
            next if selector_text.include?("@")
            next unless selector_text.match?(/::?(?:before|after|first-line|first-letter)(?![\w-])/i)

            selectors = normalize_selectors(selector_text.split(",").map { |text| {text: text.strip} })
            next if selectors.empty?

            declarations = parse_declarations(declaration_text)
            next if declarations.empty?

            StyleRule.new(selectors, declarations)
          end
        end

        def each_style_block(source)
          return enum_for(:each_style_block, source) unless block_given?

          i = 0
          while i < source.length
            open = source.index("{", i)
            break unless open

            selector = source[i...open].to_s.strip
            close = source.index("}", open + 1)
            break unless close

            body = source[(open + 1)...close].to_s
            yield selector, body
            i = close + 1
          end
        end

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
