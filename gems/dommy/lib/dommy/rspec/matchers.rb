# frozen_string_literal: true

require_relative "../internal/dom_matching"
require_relative "../internal/scope_resolution"

module Dommy
  module RSpec
    # Custom RSpec matchers for asserting against Dommy DOM objects.
    #
    # @example RSpec config
    #   require "dommy/rspec"
    #   RSpec.configure do |c|
    #     c.include Dommy::RSpec::Matchers
    #   end
    #
    # @example Usage
    #   expect(root).to contain_dom("button.primary")
    #   expect(root).to contain_dom("li", count: 3)
    #   expect(root).to contain_dom("h1", text: "Welcome")
    #   expect(root).to contain_dom_text("Submit")
    #   expect(button).to have_dom_attribute("type", "button")
    #   expect(button).to have_dom_class("primary")
    #   expect(root).to match_dom_html("<h1>Hello</h1>")
    module Matchers
      def contain_dom(selector, text: nil, count: nil)
        ContainDom.new(selector, text: text, count: count)
      end

      def contain_dom_text(text)
        ContainDomText.new(text)
      end

      def have_dom_attribute(name, value = UNSET)
        HaveDomAttribute.new(name, value)
      end

      def have_dom_class(class_name)
        HaveDomClass.new(class_name)
      end

      def match_dom_html(expected_html)
        MatchDomHtml.new(expected_html)
      end

      # Sentinel for "value was not passed" — distinguishes
      # `have_dom_attribute("disabled")` (existence only) from
      # `have_dom_attribute("disabled", "true")` (value match).
      UNSET = Object.new.freeze
      private_constant :UNSET

      # @api private
      class ContainDom
        def initialize(selector, text: nil, count: nil)
          @selector = selector
          @text = text
          @count = count
        end

        def matches?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @matched = Internal::DomMatching.filter(@scope, @selector, text: @text)
          Internal::DomMatching.count_matches?(@matched.size, @count)
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def description
          parts = ["contain DOM matching #{@selector.inspect}"]
          parts << "with text #{@text.inspect}" if @text
          parts << "(count: #{@count.inspect})" if @count
          parts.join(" ")
        end

        def failure_message
          "expected #{describe_scope} to #{description} (found #{@matched.size})"
        end

        def failure_message_when_negated
          "expected #{describe_scope} not to #{description} (found #{@matched.size})"
        end

        private

        def describe_scope
          @scope.respond_to?(:tag_name) ? "<#{@scope.tag_name.downcase}>" : @scope.class.name
        end
      end

      # @api private
      class ContainDomText
        def initialize(text)
          @text = text
        end

        def matches?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @actual_text = Internal::DomMatching.text_of(@scope)
          Internal::DomMatching.text_matches?(@actual_text, @text)
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def description
          "contain text #{@text.inspect}"
        end

        def failure_message
          "expected text to include #{@text.inspect}, got #{@actual_text.inspect}"
        end

        def failure_message_when_negated
          "expected text not to include #{@text.inspect}, got #{@actual_text.inspect}"
        end
      end

      # @api private
      class HaveDomAttribute
        def initialize(name, value)
          @name = name.to_s
          @value = value
        end

        def matches?(element)
          @element = element
          return false unless element.has_attribute?(@name)

          @actual = element.get_attribute(@name)
          unset?(@value) ? true : @actual.to_s == @value.to_s
        end

        def does_not_match?(element)
          !matches?(element)
        end

        def description
          if unset?(@value)
            "have DOM attribute #{@name.inspect}"
          else
            "have DOM attribute #{@name.inspect} = #{@value.inspect}"
          end
        end

        def failure_message
          if unset?(@value)
            "expected element to have attribute #{@name.inspect}, but it was missing"
          else
            "expected attribute #{@name.inspect} to equal #{@value.inspect}, got #{@actual.inspect}"
          end
        end

        def failure_message_when_negated
          if unset?(@value)
            "expected element NOT to have attribute #{@name.inspect}, but it was present (#{@actual.inspect})"
          else
            "expected attribute #{@name.inspect} not to equal #{@value.inspect}"
          end
        end

        private

        def unset?(value)
          value.equal?(UNSET)
        end
      end

      # @api private
      class HaveDomClass
        def initialize(class_name)
          @class_name = class_name.to_s
        end

        def matches?(element)
          @element = element
          @actual_classes = element.class_list.value.to_s.split(/\s+/)
          @actual_classes.include?(@class_name)
        end

        def does_not_match?(element)
          !matches?(element)
        end

        def description
          "have DOM class #{@class_name.inspect}"
        end

        def failure_message
          "expected element to have class #{@class_name.inspect}, got #{@actual_classes.inspect}"
        end

        def failure_message_when_negated
          "expected element NOT to have class #{@class_name.inspect}, got #{@actual_classes.inspect}"
        end
      end

      # @api private
      class MatchDomHtml
        def initialize(expected_html)
          @expected_html = expected_html
        end

        def matches?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @actual_normalized = Internal::DomMatching.normalize_html(Internal::DomMatching.html_of(@scope))
          @expected_normalized = Internal::DomMatching.normalize_html(@expected_html)
          @actual_normalized == @expected_normalized
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def description
          "match DOM HTML #{@expected_html.inspect}"
        end

        def failure_message
          "expected DOM HTML to match.\nExpected: #{@expected_normalized}\nActual:   #{@actual_normalized}"
        end

        def failure_message_when_negated
          "expected DOM HTML NOT to match #{@expected_normalized}"
        end
      end
    end
  end
end
