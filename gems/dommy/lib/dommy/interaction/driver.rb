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

      # A read-only debugging view (forms / links / buttons / fields / summary)
      # over the current scope. See Dommy::Interaction::Debug.
      def debug
        Debug.new(scope_root)
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

      # --- Accessibility-role finding (getByRole) ---

      # Elements in scope whose computed ARIA role is `role`, optionally filtered
      # by accessible `name:` (substring; `exact: true` or a Regexp for
      # precision) and `level:`. Walks the accessibility tree, so aria-hidden /
      # invisible / presentational nodes are already excluded. Possibly empty.
      def all_by_role(role, name: nil, level: nil, exact: false)
        RoleQuery.match(scope_root, role: role, name: name, level: level, exact: exact)
      end

      # The single element with role `role` (+ optional name/level). Raises
      # ElementNotFoundError when none (listing the roles that ARE present) and
      # AmbiguousElementError when more than one.
      def find_by_role(role, name: nil, level: nil, exact: false)
        matches = all_by_role(role, name: name, level: level, exact: exact)
        raise ElementNotFoundError, role_not_found_message(role, name, level) if matches.empty?
        raise AmbiguousElementError, "#{matches.size} elements with role #{role.to_s.inspect}" if matches.size > 1

        matches.first
      end

      def has_role?(role, name: nil, level: nil, exact: false)
        !all_by_role(role, name: name, level: level, exact: exact).empty?
      end

      def has_no_role?(role, name: nil, level: nil, exact: false)
        all_by_role(role, name: name, level: level, exact: exact).empty?
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

      # Type into the element matching `selector` (focusing it first). Each
      # key is a Symbol for a named key (:enter, :arrow_down, :escape, … see
      # EventSynthesis::NAMED_KEYS) or a String typed character by character
      # (keydown -> keypress -> beforeinput -> insertion + input -> keyup).
      # Default actions mirror a browser's: characters insert into a text
      # field, Backspace deletes, Enter inserts a newline in a textarea and
      # triggers the owning form's implicit submission elsewhere. Preventing
      # keydown / keypress / beforeinput suppresses the default action, so
      # SPA keyboard handlers behave as they would in a browser.
      #
      #   browser.send_keys "#q", :arrow_down, :enter
      #   browser.send_keys "#q", "hello"
      def send_keys(selector, *keys)
        send_keys_to(find(selector), *keys)
      end

      # Element-based variant of #send_keys, for hosts that already hold the
      # element (capybara-dommy's Node#send_keys). Same semantics.
      def send_keys_to(element, *keys)
        EventSynthesis.focus(element)
        keys.each { |key| dispatch_send_key(element, key) }
        after_interaction
        element
      end

      # Compose text through an IME, with the canonical (Chrome-like) event
      # sequence an input method produces. `updates` are the visible
      # composition states (e.g. ["に", "にほんご"] while converting to
      # 日本語); each dispatches a `Process` keydown (keyCode 229),
      # compositionupdate, the insertCompositionText beforeinput/input pair
      # (`isComposing: true`, the field's value shows the composing text),
      # and keyup. `commit: true` (default) then fires compositionend with
      # `text` and leaves it in the field; `commit: false` cancels the
      # composition, restoring the field's prior value.
      #
      #   browser.ime_input "#q", "日本語", updates: ["に", "にほんご"]
      #   browser.ime_input "#q", "", updates: ["に"], commit: false
      #
      # A block runs after each composition state (with the update string),
      # so a test can let virtual time pass mid-composition — e.g. prove a
      # debounced handler that guards on `event.isComposing` stays quiet
      # while the user pauses to pick a conversion candidate:
      #
      #   browser.ime_input "#q", "日本語", updates: ["に", "にほんご"] do
      #     browser.advance_time(400)  # longer than the debounce
      #   end
      #
      # Handlers that guard on `event.isComposing` (deferring work until
      # compositionend) therefore behave exactly as they would under a real
      # IME — something a real-browser test cannot drive deterministically.
      def ime_input(selector, text, updates: nil, commit: true)
        element = find(selector)
        EventSynthesis.focus(element)
        text = text.to_s
        updates = Array(updates || (text.empty? ? [] : [text])).map(&:to_s)
        base = element.respond_to?(:value) ? element.value.to_s : ""

        EventSynthesis.keydown(element, "Process", "", {"keyCode" => 229})
        EventSynthesis.compositionstart(element)
        updates.each_with_index do |update, i|
          EventSynthesis.keydown(element, "Process", "", {"keyCode" => 229, "isComposing" => true}) if i.positive?
          EventSynthesis.compositionupdate(element, update)
          field_interactor.set_composition_text(element, base, update)
          EventSynthesis.keyup(element, "Process", "", {"isComposing" => true})
          yield update if block_given?
        end

        if commit
          unless text == updates.last
            EventSynthesis.compositionupdate(element, text)
            field_interactor.set_composition_text(element, base, text)
          end
          EventSynthesis.compositionend(element, text)
        else
          field_interactor.cancel_composition_text(element, base)
          EventSynthesis.compositionend(element, "")
        end
        after_interaction
        element
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
        return unless submit_button_element?(element)

        form = finder.form_for(element)
        return unless form

        # Centralized form submission: fires a real SubmitEvent (with this
        # button as the submitter) and hands navigation to the delegate.
        form.__run_form_submission__(element)
      end

      # The includer (Browser / Rack::Session) may define the actual rule for
      # "is this a submit button"; treat none as present otherwise.
      def submit_button_element?(element)
        respond_to?(:submit_button?, true) && submit_button?(element)
      end

      # The form's first submit button in tree order (the one Enter's
      # implicit-submission default action would activate), or nil for a
      # buttonless form. Reuses #submit_button_element? so this agrees with
      # #submit_owning_form on what counts as a submit button.
      def default_submit_button(form)
        form.query_selector_all("button, input").find { |el| submit_button_element?(el) }
      end

      # --- send_keys internals ---

      def dispatch_send_key(element, key)
        case key
        when Symbol
          named = EventSynthesis::NAMED_KEYS[key] ||
                  raise(ArgumentError, "unknown key #{key.inspect} (known: #{EventSynthesis::NAMED_KEYS.keys.join(", ")})")
          send_named_key(element, key, named[0], named[1])
        when String
          key.each_char { |char| send_character(element, char) }
        else
          raise ArgumentError, "send_keys takes Symbols (named keys) or Strings (typed text), got #{key.inspect}"
        end
      end

      def send_named_key(element, name, key, code)
        unless EventSynthesis.keydown(element, key, code)
          case name
          when :enter then enter_default_action(element)
          when :space then typed_character_default_action(element, " ", "Space")
          when :backspace then field_interactor.backspace(element)
          end
        end
        EventSynthesis.keyup(element, key, code)
      end

      def send_character(element, char)
        code = EventSynthesis.char_code(char)
        typed_character_default_action(element, char, code) unless EventSynthesis.keydown(element, char, code)
        EventSynthesis.keyup(element, char, code)
      end

      # An un-prevented printable keydown fires keypress; an un-prevented
      # keypress inserts the character (beforeinput -> value -> input).
      def typed_character_default_action(element, char, code)
        return if EventSynthesis.keypress(element, char, code)

        field_interactor.insert_text(element, char)
      end

      # Enter's default action: newline in a textarea; elsewhere the owning
      # form's implicit submission — click the form's default (first) submit
      # button so its handlers run, or dispatch a cancelable submit event
      # directly when the form has no submit button (HTML implicit submission).
      def enter_default_action(element)
        return field_interactor.insert_text(element, "\n") if element.local_name == "textarea"
        return unless element.respond_to?(:form) && (form = element.form)

        submitter = default_submit_button(form)
        if submitter
          submit_owning_form(submitter) unless EventSynthesis.click(submitter)
        else
          # No submit button: HTML implicit submission with no submitter.
          form.__run_form_submission__(nil)
        end
      end

      # "no element with role …" plus the roles that WERE present (the most
      # useful thing to see when a role query misses).
      def role_not_found_message(role, name, level)
        base = "no element with role #{role.to_s.inspect}"
        base += " named #{name.inspect}" if name
        base += " at level #{level}" if level
        rows = RoleQuery.available(scope_root)
        return base if rows.empty?

        "#{base}\n\nAvailable roles:\n#{rows.map { |row| "  #{row}" }.join("\n")}"
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
