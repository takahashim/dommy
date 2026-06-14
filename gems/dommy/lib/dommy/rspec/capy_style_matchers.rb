# frozen_string_literal: true

require_relative "../internal/dom_matching"
require_relative "../internal/scope_resolution"

module Dommy
  module RSpec
    # Capybara-style RSpec matchers backed by Dommy.
    #
    # These mirror Capybara's matcher names (`have_selector`, `have_content`,
    # `have_link`, etc.) so existing Capybara test suites can be migrated
    # to a pure-Ruby DOM stack with minimal code changes.
    #
    # Because the names collide with Capybara::RSpecMatchers, this module
    # should be included into specs that DO NOT also include Capybara —
    # typically view / component / request specs, with feature specs
    # left to Capybara. See the README for a `type:` split example.
    #
    # @example
    #   require "dommy/rspec/capy_style_matchers"
    #
    #   RSpec.configure do |c|
    #     c.include Dommy::TestHelpers,                type: :view
    #     c.include Dommy::RSpec::CapyStyleMatchers,   type: :view
    #   end
    #
    #   expect(dom).to have_selector("button.primary")
    #   expect(dom).to have_content("Welcome")
    #   expect(dom).to have_link("Sign up", href: "/signup")
    module CapyStyleMatchers
      def have_selector(selector, **opts)
        HaveSelector.new(selector, **opts)
      end

      alias_method :have_css, :have_selector

      def have_no_selector(selector, **opts)
        HaveNoSelector.new(selector, **opts)
      end

      alias_method :have_no_css, :have_no_selector

      def have_content(text, **opts)
        HaveContent.new(text, **opts)
      end

      alias_method :have_text, :have_content

      def have_no_content(text, **opts)
        HaveNoContent.new(text, **opts)
      end

      alias_method :have_no_text, :have_no_content

      def have_link(text = nil, **opts)
        HaveLink.new(text, **opts)
      end

      def have_no_link(text = nil, **opts)
        HaveNoLink.new(text, **opts)
      end

      def have_button(text = nil, **opts)
        HaveButton.new(text, **opts)
      end

      def have_no_button(text = nil, **opts)
        HaveNoButton.new(text, **opts)
      end

      def have_field(name_or_label = nil, **opts)
        HaveField.new(name_or_label, **opts)
      end

      def have_no_field(name_or_label = nil, **opts)
        HaveNoField.new(name_or_label, **opts)
      end

      # ----- Base behavior shared across element-finding matchers -----

      # @api private
      class Base
        def initialize(selector, **opts)
          @selector = selector
          @text = opts[:text] || opts[:content]
          @count = opts[:count]
          @exact = opts[:exact] || opts[:exact_text]
          @visible = opts.fetch(:visible, :visible)
          # :wait is accepted for Capybara compatibility but ignored
          # (Dommy is synchronous).
        end

        def matches?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @matched = find_matches(@scope)
          count_ok?(@matched.size)
        end

        def does_not_match?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @matched = find_matches(@scope)
          if @count
            !count_ok?(@matched.size)
          else
            @matched.empty?
          end
        end

        def description
          "have #{describe_target}"
        end

        def failure_message
          "expected to find #{describe_target}, found #{@matched.size}"
        end

        def failure_message_when_negated
          "expected NOT to find #{describe_target}, found #{@matched.size}"
        end

        private

        def find_matches(scope)
          elements = scope.query_selector_all(query_selector).to_a
          elements = filter_by_text(elements) if @text
          Internal::DomMatching.filter_by_visibility(elements, @visible)
        end

        def filter_by_text(elements)
          elements.select { |el| Internal::DomMatching.text_matches?(el.text_content, @text, exact: @exact) }
        end

        def query_selector
          @selector
        end

        def count_ok?(actual)
          Internal::DomMatching.count_matches?(actual, @count)
        end

        def describe_target
          parts = [describe_what]
          parts << "with text #{@text.inspect}" if @text
          parts << "(count: #{@count.inspect})" if @count
          parts.join(" ")
        end

        def describe_what
          "elements matching #{@selector.inspect}"
        end
      end

      # @api private
      # Mixin that flips matches? / does_not_match? for the "no_*" matchers,
      # so each negative matcher reads identically to its positive twin
      # but with inverted assertions.
      module Negated
        def matches?(scope)
          !super
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def failure_message
          "expected NOT to find #{describe_target}, found #{@matched.size}"
        end

        def failure_message_when_negated
          "expected to find #{describe_target}, found #{@matched.size}"
        end
      end

      class HaveSelector < Base
      end

      class HaveNoSelector < HaveSelector
        include Negated
      end

      # @api private
      class HaveContent
        def initialize(text, **opts)
          @text = text
          @exact = opts[:exact] || opts[:exact_text]
        end

        def matches?(scope)
          @scope = Internal::ScopeResolution.resolve(scope)
          @actual = Internal::DomMatching.text_of(@scope)
          Internal::DomMatching.text_matches?(@actual, @text, exact: @exact)
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def description
          "have content #{@text.inspect}"
        end

        def failure_message
          "expected text to include #{@text.inspect}, got #{@actual.inspect}"
        end

        def failure_message_when_negated
          "expected text NOT to include #{@text.inspect}, got #{@actual.inspect}"
        end
      end

      # @api private
      class HaveNoContent < HaveContent
        def matches?(scope)
          !super
        end

        def does_not_match?(scope)
          !matches?(scope)
        end

        def failure_message
          "expected text NOT to include #{@text.inspect}, got #{@actual.inspect}"
        end

        def failure_message_when_negated
          "expected text to include #{@text.inspect}, got #{@actual.inspect}"
        end
      end

      # @api private
      class HaveLink < Base
        def initialize(text, **opts)
          super("a[href]", text: text, **opts.reject { |k, _| k == :href })
          @href = opts[:href]
        end

        private

        def find_matches(scope)
          elements = super
          return elements unless @href

          elements.select do |a|
            href = a.get_attribute("href").to_s
            case @href
            when Regexp
              href.match?(@href)
            else
              href == @href.to_s
            end
          end
        end

        def describe_what
          @href ? "link to #{@href.inspect}" : "link"
        end
      end

      class HaveNoLink < HaveLink
        include Negated
      end

      # @api private
      class HaveButton < Base
        def initialize(text, **opts)
          # Buttons are <button> elements OR <input type="submit|button|reset">.
          super("button, input[type='submit'], input[type='button'], input[type='reset']", text: text, **opts)
          @type_filter = opts[:type]
        end

        private

        def find_matches(scope)
          elements = super
          return elements unless @type_filter

          elements.select { |el| el.get_attribute("type") == @type_filter.to_s }
        end

        # Override Base's text filter so <input type=submit> matches by
        # its `value` attribute rather than text content.
        def filter_by_text(elements)
          elements.select do |el|
            label = el.tag_name.downcase == "input" ? el.get_attribute("value").to_s : el.text_content.to_s
            Internal::DomMatching.text_matches?(label, @text, exact: @exact)
          end
        end

        def describe_what
          "button"
        end
      end

      class HaveNoButton < HaveButton
        include Negated
      end

      # @api private
      # have_field locates form fields by name attribute, id, or label text.
      class HaveField < Base
        def initialize(name_or_label, **opts)
          super("input, textarea, select", text: nil, **opts.reject { |k, _| %i[with type].include?(k) })
          @locator = name_or_label
          @with_value = opts[:with]
          @type_filter = opts[:type]
        end

        private

        def find_matches(scope)
          elements = scope.query_selector_all(query_selector).to_a
          elements = elements.select { |el| matches_locator?(el, @locator) } if @locator
          elements = elements.select { |el| el.get_attribute("type") == @type_filter.to_s } if @type_filter
          elements = elements.select { |el| matches_value?(el, @with_value) } unless @with_value.nil?
          Internal::DomMatching.filter_by_visibility(elements, @visible)
        end

        def matches_locator?(el, locator)
          locator_str = locator.to_s
          return true if el.get_attribute("name") == locator_str
          return true if el.get_attribute("id") == locator_str
          return true if matches_label?(el, locator_str)

          false
        end

        # Find a <label> with matching text whose `for=` points to this element,
        # or that wraps this element.
        def matches_label?(el, label_text)
          @scope.query_selector_all("label").any? do |label|
            next false unless label.text_content.to_s.strip.include?(label_text)

            for_attr = label.get_attribute("for")
            next true if for_attr && el.get_attribute("id") == for_attr

            label.contains?(el)
          end
        end

        def matches_value?(el, expected_value)
          actual = el.respond_to?(:value) ? el.value.to_s : el.get_attribute("value").to_s
          actual == expected_value.to_s
        end

        def describe_what
          @locator ? "field #{@locator.inspect}" : "field"
        end
      end

      class HaveNoField < HaveField
        include Negated
      end

      # Prepended to every concrete matcher so it sits first in the method
      # resolution order: it remembers the matched subject and wraps the
      # matcher's own `failure_message` (via `super`) with any extra context a
      # host registered through `Dommy::RSpec.failure_context` (e.g. dommy-rails
      # appends a recent trace for a trace-enabled session). With no context
      # registered the message is returned unchanged, so existing behavior — and
      # existing message assertions — are preserved.
      module FailureContext
        def matches?(scope)
          @__dommy_subject = scope
          super
        end

        def does_not_match?(scope)
          @__dommy_subject = scope
          super
        end

        def failure_message
          Dommy::RSpec.__decorate_failure(super, @__dommy_subject)
        end

        def failure_message_when_negated
          Dommy::RSpec.__decorate_failure(super, @__dommy_subject)
        end
      end

      [HaveSelector, HaveNoSelector, HaveContent, HaveNoContent,
        HaveLink, HaveNoLink, HaveButton, HaveNoButton,
        HaveField, HaveNoField].each { |matcher| matcher.prepend(FailureContext) }
    end

    class << self
      # A `->(subject) { String | nil }` consulted when a matcher fails: its
      # return value is appended to the failure message. Hosts set this to add
      # context (dommy-rails registers a recent-trace summary for trace-enabled
      # sessions). nil (the default) leaves every message untouched.
      attr_accessor :failure_context
    end

    # Append the host's failure context to `message` for `subject`, or return
    # `message` unchanged. Never raises out of a failure path: a misbehaving
    # context proc must not mask the real assertion failure.
    def self.__decorate_failure(message, subject)
      return message unless failure_context && subject

      extra = failure_context.call(subject)
      extra ? "#{message}\n\n#{extra}" : message
    rescue StandardError
      message
    end
  end
end
