# frozen_string_literal: true

require_relative "../internal/dom_matching"
require_relative "../internal/scope_resolution"

module Dommy
  module Minitest
    # Custom Minitest assertions for testing Dommy DOM objects.
    #
    # @example
    #   require "dommy/minitest"
    #
    #   class MyTest < Minitest::Test
    #     include Dommy::Minitest::Assertions
    #
    #     def test_renders_button
    #       dom = parse_html("<button class='primary'>Submit</button>")
    #       assert_dom_contains(dom, "button.primary")
    #       assert_dom_contains_text(dom, "Submit")
    #     end
    #   end
    module Assertions
      def assert_dom_contains(scope, selector, text: nil, count: nil, msg: nil)
        matched = dom_matched_for(scope, selector, text: text)
        msg ||= "expected to contain DOM matching #{selector.inspect}" \
          "#{text ? " with text #{text.inspect}" : ""}" \
          "#{count ? " (count: #{count.inspect})" : ""}, found #{matched.size}"
        assert(Internal::DomMatching.count_matches?(matched.size, count), msg)
      end

      def refute_dom_contains(scope, selector, text: nil, count: nil, msg: nil)
        matched = dom_matched_for(scope, selector, text: text)
        msg ||= "expected NOT to contain DOM matching #{selector.inspect}" \
          "#{text ? " with text #{text.inspect}" : ""}, found #{matched.size}"
        refute(Internal::DomMatching.count_matches?(matched.size, count), msg)
      end

      def assert_dom_contains_text(scope, text, msg: nil)
        actual = dom_text_of(scope)
        msg ||= "expected text to include #{text.inspect}, got #{actual.inspect}"
        assert(Internal::DomMatching.text_matches?(actual, text), msg)
      end

      def refute_dom_contains_text(scope, text, msg: nil)
        actual = dom_text_of(scope)
        msg ||= "expected text NOT to include #{text.inspect}, got #{actual.inspect}"
        refute(Internal::DomMatching.text_matches?(actual, text), msg)
      end

      # Without a value argument, checks attribute existence only.
      # With a value, checks string equality.
      def assert_dom_has_attribute(element, name, value = UNSET, msg: nil)
        present = element.has_attribute?(name.to_s)
        if value.equal?(UNSET)
          msg ||= "expected element to have attribute #{name.inspect}"
          assert(present, msg)
        else
          actual = element.get_attribute(name.to_s)
          msg ||= "expected attribute #{name.inspect} to equal #{value.inspect}, got #{actual.inspect}"
          assert_equal(value.to_s, actual.to_s, msg)
        end
      end

      def refute_dom_has_attribute(element, name, msg: nil)
        present = element.has_attribute?(name.to_s)
        msg ||= "expected element NOT to have attribute #{name.inspect}"
        refute(present, msg)
      end

      def assert_dom_has_class(element, class_name, msg: nil)
        actual_classes = element.class_list.value.to_s.split(/\s+/)
        msg ||= "expected element to have class #{class_name.inspect}, got #{actual_classes.inspect}"
        assert_includes(actual_classes, class_name.to_s, msg)
      end

      def refute_dom_has_class(element, class_name, msg: nil)
        actual_classes = element.class_list.value.to_s.split(/\s+/)
        msg ||= "expected element NOT to have class #{class_name.inspect}, got #{actual_classes.inspect}"
        refute_includes(actual_classes, class_name.to_s, msg)
      end

      def assert_dom_html_equal(scope, expected_html, msg: nil)
        scope = Internal::ScopeResolution.resolve(scope)
        actual_n = Internal::DomMatching.normalize_html(Internal::DomMatching.html_of(scope))
        expected_n = Internal::DomMatching.normalize_html(expected_html)
        msg ||= "expected DOM HTML to match.\nExpected: #{expected_n}\nActual:   #{actual_n}"
        assert_equal(expected_n, actual_n, msg)
      end

      # Sentinel for "value was not passed"
      UNSET = Object.new.freeze
      private_constant :UNSET

      private

      def dom_matched_for(scope, selector, text:)
        Internal::DomMatching.filter(Internal::ScopeResolution.resolve(scope), selector, text: text)
      end

      def dom_text_of(scope)
        Internal::DomMatching.text_of(Internal::ScopeResolution.resolve(scope))
      end
    end
  end
end
