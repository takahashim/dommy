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

      def dispatch(element, key)
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

      private

      def send_named_key(element, name, key, code)
        unless EventSynthesis.keydown(element, key, code)
          case name
          when :enter then enter_default_action(element)
          when :space then space_default_action(element)
          when :backspace then @field_interactor.backspace(element)
          end
        end
        EventSynthesis.keyup(element, key, code)
      end

      # Space's default action: activate a focused button-like control — a
      # <button>, or an <input> button / checkbox / radio — as if clicked (so
      # Space toggles a focused checkbox / submits via a focused button), and
      # type a space anywhere else (a text field). Activation is a bare click
      # (no pointer/mouse events), like a keyboard-triggered activation.
      SPACE_ACTIVATED_INPUT_TYPES = %w[button submit reset checkbox radio image].freeze
      def space_default_action(element)
        if space_activates?(element)
          element.click
        else
          typed_character_default_action(element, " ", "Space")
        end
      end

      def space_activates?(element)
        name = element.local_name
        return true if name == "button"
        return false unless name == "input"

        SPACE_ACTIVATED_INPUT_TYPES.include?(element.type.to_s.downcase)
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

        @field_interactor.insert_text(element, char)
      end

      # Enter's default action: newline in a textarea; elsewhere the owning
      # form's implicit submission — click the form's default (first) submit
      # button so its handlers run, or dispatch a cancelable submit event
      # directly when the form has no submit button (HTML implicit submission).
      def enter_default_action(element)
        return @field_interactor.insert_text(element, "\n") if element.local_name == "textarea"
        return unless element.respond_to?(:form) && (form = element.form)

        submitter = default_submit_button(form)
        if submitter
          # Clicking the default submit button runs its activation behavior
          # (form submission); a prevented click naturally submits nothing.
          EventSynthesis.click(submitter)
        else
          # No submit button: HTML implicit submission with no submitter.
          form.__run_form_submission__(nil)
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
