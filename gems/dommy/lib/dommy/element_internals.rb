# frozen_string_literal: true

module Dommy
  # `ElementInternals` (HTML §4.13.7): what `attachInternals()` hands a custom
  # element — its shadow root even when closed, its custom states (the
  # `states` CustomStateSet, matched by `:state()`), default ARIA semantics,
  # and, for a form-associated custom element, the form control surface:
  # its submission value, its validity, its form owner and labels.
  #
  # `states` lives JS-side (a setlike over a JS Set, host_runtime.js), which
  # mirrors each change here (#__internal_set_states__).
  class ElementInternals
    include Bridge::Methods

    # The ARIAMixin attributes (role and aria*), which on ElementInternals
    # are the element's default ARIA semantics rather than reflections.
    ARIA_ATTRIBUTES = Internal::IdlReflection::TABLE.fetch("Element").keys
                                                    .select { |name| name.start_with?("aria") || name == "role" }
                                                    .to_set.freeze

    # What the host answers (`states` is the JS half's).
    JS_PROPERTY_NAMES = (%w[shadowRoot form labels willValidate validity validationMessage] +
                         ARIA_ATTRIBUTES.to_a).freeze

    attr_reader :target, :states, :submission_value, :state

    def initialize(target)
      @target = target
      @states = []
      @aria = {}
      @submission_value = nil
      @state = nil
      @validity_flags = {}
      @validation_message = ""
      @validity = nil
    end

    # Whether the custom state `name` is set (`:state(name)`).
    def state?(name) = @states.include?(name)

    def __internal_set_states__(list)
      @states = Array(list).map(&:to_s)
      @target.owner_document&.__internal_note_selector_state_change__
      nil
    end

    # ---- shadowRoot ----

    # The target's shadow root, when it is one attachShadow made while the
    # target was being (or had been) constructed: "available to element
    # internals".
    def shadow_root
      root = @target.respond_to?(:__internal_shadow_root__) ? @target.__internal_shadow_root__ : nil
      root if root.respond_to?(:__internal_available_to_internals__?) && root.__internal_available_to_internals__?
    end

    # ---- form-associated custom elements ----

    # `setFormValue(value, state)`: a File, a string or a FormData (or null),
    # the submission value; `state` defaults to the value.
    def set_form_value(value, state = Bridge::UNDEFINED)
      require_form_associated!
      @submission_value = form_value(value)
      @state = state.equal?(Bridge::UNDEFINED) ? @submission_value : form_value(state)
      nil
    end

    def form
      require_form_associated!
      @target.__internal_form_owner__
    end

    def labels
      require_form_associated!
      @target.labels_node_list
    end

    def will_validate
      require_form_associated!
      !barred?
    end

    def validity
      require_form_associated!
      @validity ||= InternalsValidityState.new(self)
    end

    def validation_message
      require_form_associated!
      return "" if barred? || validity_flags_clear?

      @validation_message
    end

    # `setValidity(flags, message, anchor)`: a flag set without a message is a
    # TypeError; an anchor that is not a shadow-including descendant of the
    # target is a NotFoundError.
    def set_validity(flags = nil, message = Bridge::UNDEFINED, anchor = Bridge::UNDEFINED)
      require_form_associated!
      flags = flags.is_a?(Hash) ? flags : {}
      set = ValidityState::FLAGS.to_h { |name| [name, Internal::WebIDL.boolean(flags[name])] }
      message = message.equal?(Bridge::UNDEFINED) || message.nil? ? "" : message.to_s
      if set.values.any? && message.empty?
        raise Bridge::TypeError, "setValidity needs a message when a flag is set"
      end

      anchor = nil if anchor.equal?(Bridge::UNDEFINED)
      raise Bridge::TypeError, "the validation anchor is not an HTMLElement" unless anchor.nil? || anchor.is_a?(HTMLElement)

      @validity_flags = set
      @validation_message = set.values.any? ? message.gsub(/\r\n?/, "\n") : ""
      if anchor && !Internal::Retargeting.shadow_including_inclusive_ancestor?(@target, anchor)
        raise DOMException::NotFoundError, "the validation anchor is not a shadow-including descendant of the element"
      end
      @target.owner_document&.__internal_note_selector_state_change__
      nil
    end

    def check_validity
      require_form_associated!
      return true if barred? || validity_flags_clear?

      @target.dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true).__internal_mark_trusted__)
      false
    end

    def report_validity
      check_validity
    end

    def __internal_flag__(name) = @validity_flags.fetch(name, false)

    def validity_flags_clear? = @validity_flags.values.none?

    # Barred from constraint validation: disabled, readonly, or in a datalist.
    def barred?
      @target.__internal_actually_disabled__ || @target.__internal_has_attribute__?("readonly") ||
        !@target.closest("datalist").nil?
    end

    # ---- Bridge protocol ----

    js_methods %w[setFormValue setValidity checkValidity reportValidity]

    def __js_get__(key)
      return @states.dup if key == "__states"

      case key
      when "shadowRoot" then shadow_root
      when "form" then form
      when "labels" then labels
      when "willValidate" then will_validate
      when "validity" then validity
      when "validationMessage" then validation_message
      else
        ARIA_ATTRIBUTES.include?(key) ? @aria[key] : Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless ARIA_ATTRIBUTES.include?(key)

      @aria[key] = value.equal?(Bridge::UNDEFINED) ? nil : value
      nil
    end

    def __js_call__(method, args)
      # The JS half's CustomStateSet mirrors its states here.
      return __internal_set_states__(args[0]) if method == "__setStates"

      case method
      when "setFormValue" then set_form_value(*args.first(2))
      when "setValidity" then set_validity(*args.first(3))
      when "checkValidity" then check_validity
      when "reportValidity" then report_validity
      end
    end

    private

    # The target's definition is form-associated. (Browsers let a
    # constructor that is still running — an upgrade's — use the API too;
    # the element only joins its form once it is custom.)
    def require_form_associated!
      state = @target.__internal_custom_element_state__
      definition = @target.__internal_ce_data__.definition if %w[precustomized custom].include?(state)
      return if definition&.form_associated?

      raise DOMException::NotSupportedError, "the element is not a form-associated custom element"
    end

    def form_value(value)
      return nil if value.nil? || value.equal?(Bridge::UNDEFINED)
      return value if value.is_a?(FormData) || value.is_a?(Blob)

      value.to_s
    end

    # The ValidityState of a form-associated custom element: the flags its
    # internals set (setValidity), nothing it computes.
    class InternalsValidityState < ValidityState
      def initialize(internals)
        super(nil)
        @internals = internals
      end

      FLAGS.each do |flag|
        method_name = flag.gsub(/([A-Z])/) { "_#{::Regexp.last_match(1).downcase}" }
        define_method(method_name) { @internals.__internal_flag__(flag) }
      end

      def valid = @internals.validity_flags_clear?
    end
  end
end
