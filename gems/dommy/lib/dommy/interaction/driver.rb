# frozen_string_literal: true

module Dommy
  module Interaction
    # The shared interaction surface mixed into both `Dommy::Rack::Session` and
    # `Dommy::Browser`: element finding, scoping, field interaction, generic
    # click, and query matchers — Capybara's vocabulary, in one place. The
    # includer must provide `#document`; it may override `#after_interaction`
    # (called after each interaction's events are dispatched) to settle a JS
    # runtime. Navigation verbs (`click_link` / `click_button` that issue
    # requests) stay in the host, which reuses `#finder` / EventSynthesis.
    module Driver
      # --- Scoping ---

      # The node finds and matchers run against: the innermost active scope, or
      # the document when none is open.
      def scope_root
        (@scope_stack ||= []).last || document
      end

      # Push `node` as the active scope for the block, restoring afterward.
      # Returns the block value, or the node when no block is given.
      def with_scope(node)
        (@scope_stack ||= []).push(node)
        begin
          block_given? ? yield(self) : node
        ensure
          @scope_stack.pop
        end
      end

      # Scope finds/matchers to the element matched by `selector` for the block.
      def within(selector, &block)
        node = scope_root&.query_selector(selector)
        raise ElementNotFoundError, "no element matching #{selector.inspect}" unless node

        with_scope(node, &block)
      end

      # Visible text of the current scope (document via <body>, else the node).
      def scope_text
        root = scope_root
        return "" unless root
        return Internal::DomMatching.rendered_text(root.body) if root.respond_to?(:body)

        root.respond_to?(:child_nodes) ? Internal::DomMatching.rendered_text(root) : ""
      end

      # --- Finding ---

      def finder
        Locator.new(scope_root)
      end

      def field_interactor
        FieldInteractor.new(finder, document)
      end

      # The single element matching `selector` in scope (raises if none).
      # The first element matching `selector` in scope (raises if none). `text:`
      # keeps only elements whose text contains the String (or matches the
      # Regexp).
      def find(selector, text: nil)
        all(selector, text: text).first ||
          raise(ElementNotFoundError, "no element matching #{selector.inspect}#{" with text #{text.inspect}" if text}")
      end

      # All elements matching `selector` in scope (possibly empty), optionally
      # filtered by `text:`.
      def all(selector, text: nil)
        nodes = scope_root ? scope_root.query_selector_all(selector).to_a : []
        text.nil? ? nodes : nodes.select { |node| text_matches?(node, text) }
      end

      # --- Interaction ---

      # Click any element matched by a CSS selector, firing the full browser
      # event sequence so JS click handlers run.
      def click(selector)
        element = find(selector)
        prevented = EventSynthesis.click(element)
        # Browser activation behavior: an un-prevented click on a submit button
        # runs form submission, whose JS-observable effect is a `submit` event
        # on the owning form (a SPA handles it / preventDefaults navigation).
        # This makes `click "button[type=submit]"` behave like a real click.
        submit_owning_form(element) unless prevented
        after_interaction
        element
      end

      def fill_in(locator, with:)
        result = field_interactor.fill_in(locator, with: with)
        after_interaction
        result
      end

      def choose(locator)
        result = field_interactor.choose(locator)
        after_interaction
        result
      end

      def check(locator)
        result = field_interactor.check(locator)
        after_interaction
        result
      end

      def uncheck(locator)
        result = field_interactor.uncheck(locator)
        after_interaction
        result
      end

      def select(value, from:)
        result = field_interactor.select(value, from: from)
        after_interaction
        result
      end

      def unselect(value, from:)
        result = field_interactor.unselect(value, from: from)
        after_interaction
        result
      end

      def attach_file(locator, path)
        result = field_interactor.attach_file(locator, path)
        after_interaction
        result
      end

      # --- Matchers ---

      # True when an element matches `selector` in scope. `text:` keeps only
      # elements whose text contains the String (or matches the Regexp);
      # `count:` requires an exact number of matches.
      def has_css?(selector, text: nil, count: nil)
        nodes = scope_root ? scope_root.query_selector_all(selector).to_a : []
        nodes = nodes.select { |node| text_matches?(node, text) } unless text.nil?
        count ? nodes.size == count : !nodes.empty?
      end

      def has_no_css?(selector, text: nil, count: nil) = !has_css?(selector, text: text, count: count)

      # True when the current scope's text contains `text` (a String substring)
      # or matches it (a Regexp).
      def has_text?(text)
        content = scope_text
        text.is_a?(Regexp) ? content.match?(text) : content.include?(text.to_s)
      end

      def has_no_text?(text) = !has_text?(text)

      def has_link?(locator) = element_present? { finder.find_link(locator) }
      def has_button?(locator) = element_present? { finder.find_button(locator) }
      def has_field?(locator) = element_present? { finder.find_field(locator) }

      # A no-op the includer overrides to settle a JS runtime after events.
      def after_interaction
        nil
      end

      private

      # Dispatch a `submit` event on the form owning a clicked submit button.
      # Real navigation on an un-prevented submit is a host (Session) concern;
      # here we only surface the event so SPA handlers run.
      def submit_owning_form(element)
        return unless respond_to?(:submit_button?, true) && submit_button?(element)

        form = finder.form_for(element)
        return unless form

        form.dispatch_event(Dommy::Event.new("submit", "bubbles" => true, "cancelable" => true))
      end

      # Whether a node's text satisfies a `text:` filter (substring for a
      # String, pattern for a Regexp).
      def text_matches?(node, text)
        content = Internal::DomMatching.rendered_text(node)
        text.is_a?(Regexp) ? content.match?(text) : content.include?(text.to_s)
      end

      # True if the block finds an element. A unique or ambiguous match counts
      # as present; only "not found" counts as absent.
      def element_present?
        yield
        true
      rescue ElementNotFoundError
        false
      rescue AmbiguousElementError
        true
      end
    end
  end
end
