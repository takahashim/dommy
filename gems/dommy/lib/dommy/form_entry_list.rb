# frozen_string_literal: true

module Dommy
  # HTML's "constructing the entry list" for a form: collect the successful
  # controls in tree order, fire the `formdata` event carrying a FormData a
  # listener may mutate, and return that FormData. Both form submission
  # (Dommy::Interaction::FormSubmission) and `new FormData(form)` build on this,
  # so the two paths collect and fire identically.
  class FormEntryList
    # @param encoding [Encoding] the submission encoding, used for a
    #   hidden `_charset_`. `new FormData(form)` uses UTF-8.
    def initialize(form, submitter: nil, encoding: Encoding::UTF_8)
      @form = form
      @submitter = submitter
      @encoding = encoding
    end

    # The constructed entries as a FormData (after any `formdata` listener has
    # run), or nil when the form is already constructing its entry list — HTML
    # returns null then, which `new FormData(form)` turns into an
    # InvalidStateError and form submission into a silent return. Memoized so
    # a submission builds the list once.
    def form_data
      return @form_data if defined?(@form_data)

      @form_data = build
    end

    # HTML's "submit button": a `<button>` in the Submit Button state, or an
    # `<input>` in the Submit Button or Image Button state. Unlike the
    # activation check, a disabled one still is one.
    def self.submit_button?(el)
      case el
      when HTMLButtonElement then el.type == "submit"
      when HTMLInputElement then %w[submit image].include?(el.type)
      else false
      end
    end

    # HTML's "submittable elements": the listed elements that can be submitted.
    SUBMITTABLE_SELECTOR = "button, input, select, textarea"

    private

    def build
      return nil if @form.__internal_constructing_entry_list__

      @form.__internal_constructing_entry_list__ = true
      begin
        data = FormData.new
        collect(data)
        @form.dispatch_event(
          FormDataEvent.new("formdata", "formData" => data, "bubbles" => true).__internal_mark_trusted__
        )
        # "Return a clone of entry list": a formData kept from the event and
        # mutated later does not reach the submission.
        data.__internal_copy__
      ensure
        @form.__internal_constructing_entry_list__ = false
      end
    end

    # HTML "constructing the entry list", step 5: each submittable element whose
    # form owner is this form, in tree order. A control with a datalist
    # ancestor, a disabled one, a button other than the submitter and an
    # unchecked checkbox or radio contribute nothing; the rest contribute an
    # entry under their name, followed by their dirname entry.
    def collect(data)
      controls.each do |el|
        next unless el.closest("datalist").nil?
        next if disabled?(el)
        next if button?(el) && !submitter?(el)
        next if el.is_a?(HTMLInputElement) && %w[checkbox radio].include?(el.type) && !el.checked

        if el.is_a?(HTMLInputElement) && el.type == "image"
          emit_image_coordinates(el, data)
          next
        end
        if Internal::FormAssociatedCustomElements.face?(el)
          Internal::FormAssociatedCustomElements.append_entries(el, attr(el, "name"), data)
          next
        end

        name = attr(el, "name")
        next if blank?(name)

        collect_value(el, name, data)
        append_dirname(el, data)
      end
    end

    def collect_value(el, name, data)
      case el
      when HTMLSelectElement
        el.__internal_list_of_options__.each do |option|
          next unless option.selected
          next if Internal::ElementState.disabled_element?(option)

          data.append(name, option.value.to_s)
        end
      when HTMLInputElement
        collect_input(el, name, data)
      when HTMLTextAreaElement
        data.append(name, el.__internal_submission_value__)
      else
        data.append(name, el.value.to_s)
      end
    end

    def collect_input(el, name, data)
      case el.type
      when "checkbox", "radio"
        data.append(name, el.__internal_has_attribute__?("value") ? el.__internal_attribute_value__("value") : "on")
      when "file"
        collect_file(el, name, data)
      when "hidden"
        # A hidden `_charset_` reports the submission encoding.
        data.append(name, name.casecmp?("_charset_") ? @encoding.name : el.value.to_s)
      else
        data.append(name, el.value.to_s)
      end
    end

    def submitter?(el)
      !@submitter.nil? && el.__dommy_backend_node__.equal?(@submitter.__dommy_backend_node__)
    end

    # HTML's "button" category: `<button>`, and `<input>` in the Submit Button,
    # Image Button, Reset Button and Button states.
    def button?(el)
      el.is_a?(HTMLButtonElement) ||
        (el.is_a?(HTMLInputElement) && %w[submit image reset button].include?(el.type))
    end

    # Each File becomes its own entry; an empty file input still contributes an
    # empty File so the field name survives. A File value is kept here even for
    # a non-multipart form — reducing it to its basename is the encoder's (or
    # FormSubmission's) job.
    def collect_file(el, name, data)
      files = el.files
      if files && !files.empty?
        files.each { |file| data.append(name, file) }
      else
        data.append(name, File.new([], "", "type" => "application/octet-stream"))
      end
    end

    # An Image Button submitter contributes its selected coordinate as
    # `name.x` / `name.y`. Without layout the coordinate is (0, 0).
    def emit_image_coordinates(el, data)
      prefix = blank?(attr(el, "name")) ? "" : "#{attr(el, "name")}."
      x, y = el.__internal_selected_coordinate__
      data.append("#{prefix}x", x.to_s)
      data.append("#{prefix}y", y.to_s)
    end

    # A `dirname` on an auto-directionality text control contributes the
    # element's directionality under the dirname's name (HTML §4.10.19.2).
    def append_dirname(el, data)
      dirname = attr(el, "dirname")
      return if blank?(dirname)
      return unless Internal::Directionality.auto_directionality_form_associated?(el)

      data.append(dirname, Internal::Directionality.direction_of(el))
    end

    # The submittable elements whose form owner is this form, in tree order,
    # searched in the form's own tree (a detached form's subtree, or the shadow
    # tree it lives in) — a control may sit outside the form and point at it
    # with `form=`.
    def controls
      scope = @form.get_root_node || @form
      candidates = scope.query_selector_all(Internal::FormAssociatedCustomElements.selector(SUBMITTABLE_SELECTOR)).to_a
      candidates.select do |el|
        next false if CustomElementRegistry.valid_name?(el.local_name) && !Internal::FormAssociatedCustomElements.face?(el)

        @form.__internal_owns_control__(el)
      end
    end

    # A control is unsuccessful if it or an ancestor <fieldset> is disabled
    # (a first-legend control is exempt). The rule is shared with the `:disabled`
    # selector so both stay in step.
    def disabled?(el)
      Internal::ElementState.disabled_element?(el)
    end

    def attr(el, name)
      el&.__internal_attribute_value__(name)
    end

    def blank?(value)
      value.nil? || value.empty?
    end
  end
end
