# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's constraint validation API (§4.10.21.3), shared by every element
    # that has it — input, textarea, select, button, output, fieldset, object:
    # `willValidate`, `validity`, `validationMessage`, `checkValidity()`,
    # `reportValidity()` and `setCustomValidity()`.
    #
    # A host narrows #__internal_barred_from_constraint_validation__? with its
    # own reasons (an output, a fieldset and an object always are; an input in
    # the Hidden state is; …). What the constraints themselves are is
    # ValidityState's.
    module ConstraintValidation
      JS_METHOD_NAMES = %w[checkValidity reportValidity setCustomValidity].freeze

      def self.included(base)
        base.js_readable :validity, will_validate: "willValidate", validation_message: "validationMessage"
      end

      # [SameObject]
      def validity
        @__validity ||= ValidityState.new(self)
      end

      # "A candidate for constraint validation": not barred.
      def will_validate
        !__internal_barred_from_constraint_validation__?
      end

      # The reasons every control shares: a datalist ancestor, or being
      # (actually) disabled.
      def __internal_barred_from_constraint_validation__?
        !closest("datalist").nil? || __internal_actually_disabled__
      end

      # The custom validity error message (empty when there is none).
      def __internal_custom_validity_message__
        @custom_validity_message.to_s
      end

      # HTML: the message is the given string with newlines normalized.
      def set_custom_validity(message)
        @custom_validity_message = message.to_s.gsub(/\r\n?/, "\n")
        @document&.__internal_note_selector_state_change__
        nil
      end

      # "Satisfies its constraints": none of the validity states is true.
      def __internal_satisfies_constraints__? = validity.valid

      # Empty for a control that is barred or satisfies its constraints;
      # otherwise the custom message, or a message for the first failing
      # constraint.
      def validation_message
        return "" if !will_validate || __internal_satisfies_constraints__?

        custom = __internal_custom_validity_message__
        return custom unless custom.empty?

        ValidationMessages.for(self, validity)
      end

      # HTML "check validity steps": a candidate that fails its constraints
      # gets a trusted, cancelable `invalid` event and the answer is false.
      def check_validity
        return true if !will_validate || __internal_satisfies_constraints__?

        __internal_fire_invalid__
        false
      end

      # "Report validity steps": the same as checking, as there is no user to
      # report the problem to.
      def report_validity
        check_validity
      end

      def __internal_fire_invalid__
        dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true).__internal_mark_trusted__)
      end

      def __js_call__(method, args)
        case method
        when "checkValidity" then check_validity
        when "reportValidity" then report_validity
        when "setCustomValidity" then set_custom_validity(args[0])
        else super
        end
      end
    end

    # A localized-for-English validationMessage per failing constraint, in
    # ValidityState's flag order.
    module ValidationMessages
      module_function

      def for(element, validity)
        type = element.respond_to?(:type) ? element.type.to_s : ""
        if validity.value_missing
          case type
          when "checkbox" then "Please check this box if you want to proceed."
          when "radio" then "Please select one of these options."
          when "file" then "Please select a file."
          when "select-one", "select-multiple" then "Please select an item in the list."
          else "Please fill out this field."
          end
        elsif validity.type_mismatch
          type == "email" ? "Please enter an email address." : "Please enter a URL."
        elsif validity.pattern_mismatch
          "Please match the requested format."
        elsif validity.too_long
          "Please shorten this text to #{element.max_length} characters or less."
        elsif validity.too_short
          "Please lengthen this text to #{element.min_length} characters or more."
        elsif validity.range_underflow
          "Value must be greater than or equal to #{element.__internal_attribute_value__("min").to_s.strip}."
        elsif validity.range_overflow
          "Value must be less than or equal to #{element.__internal_attribute_value__("max").to_s.strip}."
        elsif validity.step_mismatch
          "Please enter a valid value."
        elsif validity.bad_input
          type == "number" ? "Please enter a number." : "Please enter a valid value."
        else
          "Please enter a valid value."
        end
      end
    end
  end
end
