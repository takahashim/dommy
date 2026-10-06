# frozen_string_literal: true

module Dommy
  module Interaction
    # Drives a single #send_keys key (Driver's public entry point) through the
    # browser's default-action semantics: a printable character types itself
    # (or is swallowed by a canceled keydown/keypress/beforeinput), Backspace
    # deletes, Space activates a focused button-like control or types a space,
    # and Enter inserts a newline in a textarea or triggers the owning form's
    # implicit submission. Extracted from Driver so keyboard defaulting has its
    # own home, the way field mutation has FieldInteractor.
    #
    # `submit_button_predicate:` is the includer's (Browser / Rack::Session)
    # optional rule for "is this element a submit button", used to pick the
    # form's default submit button for Enter's implicit submission; nil means
    # none is ever a submit button (implicit submission falls back to the
    # HTML no-submitter path).
    class KeySender
      def initialize(field_interactor, submit_button_predicate: nil)
        @field_interactor = field_interactor
        @submit_button_predicate = submit_button_predicate
      end

      # Modifier keys a chord (`[:shift, :tab]`) may hold down, with their
      # KeyboardEvent key / code and the modifier flag they set.
      MODIFIERS = {
        shift: ["Shift", "ShiftLeft", "shiftKey"],
        control: ["Control", "ControlLeft", "ctrlKey"],
        ctrl: ["Control", "ControlLeft", "ctrlKey"],
        alt: ["Alt", "AltLeft", "altKey"],
        meta: ["Meta", "MetaLeft", "metaKey"],
        command: ["Meta", "MetaLeft", "metaKey"],
      }.freeze

      def dispatch(element, key, modifiers = {})
        case key
        when Symbol
          named = EventSynthesis::NAMED_KEYS[key] ||
                  raise(ArgumentError, "unknown key #{key.inspect} (known: #{EventSynthesis::NAMED_KEYS.keys.join(", ")})")
          send_named_key(element, key, named[0], named[1], modifiers)
        when String
          key.each_char { |char| send_character(element, char, modifiers) }
        when Array
          send_chord(element, key, modifiers)
        else
          raise ArgumentError, "send_keys takes Symbols (named keys), Strings (typed text) or chords " \
                               "([:shift, :tab]), got #{key.inspect}"
        end
      end

      private

      # A chord: its leading modifiers are pressed (keydown), held for the
      # remaining keys, then released (keyup) in reverse order.
      def send_chord(element, keys, modifiers)
        held = keys.take_while { |k| k.is_a?(Symbol) && MODIFIERS.key?(k) }
        rest = keys.drop(held.size)
        held.each do |name|
          mod_key, mod_code, flag = MODIFIERS[name]
          modifiers = modifiers.merge(flag => true)
          EventSynthesis.keydown(target_of(element), mod_key, mod_code, modifiers)
        end
        rest.each { |k| dispatch(element, k, modifiers) }
        held.reverse_each do |name|
          mod_key, mod_code, flag = MODIFIERS[name]
          modifiers = modifiers.reject { |f, _| f == flag }
          EventSynthesis.keyup(target_of(element), mod_key, mod_code, modifiers.empty? ? nil : modifiers)
        end
      end

      def send_named_key(element, name, key, code, modifiers = {})
        target = target_of(element)
        extra = modifiers.empty? ? nil : modifiers
        unless EventSynthesis.keydown(target, key, code, extra)
          case name
          when :enter
            # Enter produces a character ("\r"), so a keypress precedes its
            # default action — which a prevented keypress suppresses.
            enter_default_action(target) unless EventSynthesis.keypress(target, key, code, extra)
          when :space then space_default_action(target)
          when :backspace then @field_interactor.backspace(target)
          when :tab then tab_default_action(target, modifiers["shiftKey"] ? :backward : :forward)
          when :escape then close_request(target)
          end
        end
        EventSynthesis.keyup(target_of(element), key, code, extra)
      end

      # Keys go to the focused element: the one send_keys targeted, unless a
      # previous key moved the focus (Tab, or a handler's focus()) — then to
      # the newly focused element, or the body when the viewport has it.
      def target_of(element)
        document = element.respond_to?(:owner_document) ? element.owner_document : nil
        return element if document.nil?

        focused = document.__internal_focused_element__
        @initial_focus ||= [focused]
        return element if @initial_focus.first.equal?(focused)

        focused || document.body || element
      end

      # Tab's default action: sequential focus navigation, forward (Shift
      # held: backward) from the focused area (HTML §6.6.5).
      def tab_default_action(element, direction)
        document = element.owner_document
        Internal::SequentialFocusNavigation.navigate(document, direction)
      end

      # Esc is the close request on a keyboard (HTML §6.9): its keydown was
      # not canceled, so the close watchers of the document's window are
      # processed — the topmost modal dialog, auto popover or CloseWatcher
      # closes.
      def close_request(element)
        window = element.owner_document.default_view
        window.__internal_close_request__ if window.respond_to?(:__internal_close_request__)
      end

      # Space's default action: activate a focused button-like control — a
      # <button>, or an <input> button / checkbox / radio — as if clicked (so
      # Space toggles a focused checkbox / submits via a focused button), and
      # type a space anywhere else (a text field). Activation is a bare click
      # (no pointer/mouse events), like a keyboard-triggered activation.
      SPACE_ACTIVATED_INPUT_TYPES = %w[button submit reset checkbox radio image].freeze
      def space_default_action(element)
        if space_activates?(element)
          EventSynthesis.keyboard_click(element)
        else
          typed_character_default_action(element, " ", "Space")
        end
      end

      def enter_activates?(element)
        return false unless element.respond_to?(:local_name) && element.namespace_uri == Internal::Namespaces::HTML

        case element.local_name
        when "button" then true
        when "a", "area" then element.__internal_has_attribute__?("href")
        when "input" then %w[button submit reset image].include?(element.type.to_s.downcase)
        else false
        end
      end

      def space_activates?(element)
        name = element.local_name
        return true if name == "button"
        return false unless name == "input"

        SPACE_ACTIVATED_INPUT_TYPES.include?(element.type.to_s.downcase)
      end

      def send_character(element, char, modifiers = {})
        target = target_of(element)
        code = EventSynthesis.char_code(char)
        extra = modifiers.empty? ? nil : modifiers
        typed_character_default_action(target, char, code, extra) unless EventSynthesis.keydown(target, char, code, extra)
        EventSynthesis.keyup(target_of(element), char, code, extra)
      end

      # An un-prevented printable keydown fires keypress; an un-prevented
      # keypress inserts the character (beforeinput -> value -> input).
      def typed_character_default_action(element, char, code, extra = nil)
        return if EventSynthesis.keypress(element, char, code, extra)

        @field_interactor.insert_text(element, char)
      end

      # Enter's default action: newline in a textarea; elsewhere the owning
      # form's implicit submission — click the form's default (first) submit
      # button so its handlers run, or dispatch a cancelable submit event
      # directly when the form has no submit button (HTML implicit submission).
      def enter_default_action(element)
        return @field_interactor.insert_text(element, "\n") if element.local_name == "textarea"
        # On a focused button or link, Enter activates it, like a click.
        return EventSynthesis.keyboard_click(element) if enter_activates?(element)

        return unless element.respond_to?(:form) && (form = element.form)

        submitter = default_submit_button(form)
        if submitter
          # Clicking the default submit button runs its activation behavior
          # (form submission); a prevented click naturally submits nothing.
          EventSynthesis.click(submitter)
        else
          # No submit button: HTML implicit submission with no submitter.
          form.__internal_run_form_submission__(nil)
        end
      end

      # The form's first submit button in tree order (the one Enter's
      # implicit-submission default action would activate), or nil for a
      # buttonless form.
      def default_submit_button(form)
        form.query_selector_all("button, input").find { |el| submit_button?(el) }
      end

      # Thin wrapper around the injected predicate — not a rule of its own,
      # just "ask whoever handed us one." Named differently from Driver's
      # submit_button_element? (which IS the rule) so the two don't read as
      # duplicate logic when scanning across files.
      def submit_button?(element)
        @submit_button_predicate&.call(element) || false
      end
    end
  end
end
