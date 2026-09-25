# frozen_string_literal: true

module Dommy
  # HTML's "constructing the entry list" for a form: collect the successful
  # controls in tree order, fire the `formdata` event carrying a FormData a
  # listener may mutate, and return that FormData. Both form submission
  # (Dommy::Interaction::FormSubmission) and `new FormData(form)` build on this,
  # so the two paths collect and fire identically.
  class FormEntryList
    # The controls whose `dirname` contributes a directionality entry.
    DIRNAME_ELEMENTS = %w[INPUT TEXTAREA].freeze

    # @param encoding [Encoding] the submission encoding, used for a
    #   value-less hidden `_charset_`. `new FormData(form)` uses UTF-8.
    def initialize(form, submitter: nil, encoding: Encoding::UTF_8)
      @form = form
      @submitter = submitter
      @encoding = encoding
    end

    # The constructed entries as a FormData (after any `formdata` listener has
    # run). Memoized so a submission builds the list once.
    def form_data
      @form_data ||= build
    end

    private

    def build
      data = FormData.new
      collect(data)
      fire_formdata(data)
      data
    end

    # Returns ordered entries in the FormData. The clicked submitter is emitted
    # at its document position; only if it isn't among the form's controls do we
    # append it at the end.
    def collect(data)
      submitter_emitted = false
      controls.each do |el|
        next if disabled?(el)

        case el.tag_name
        when "INPUT" then submitter_emitted = true if collect_input(el, data)
        when "TEXTAREA" then collect_named(el, normalize_newlines(el.value.to_s), data)
        when "SELECT" then collect_select(el, data)
        when "BUTTON" then submitter_emitted = true if collect_button(el, data)
        end
        append_dirname(el, data)
      end
      append_submitter(data) unless submitter_emitted
    end

    # Returns true when this input is the clicked submitter (and was emitted).
    def collect_input(el, data)
      type = el.type
      if %w[submit image].include?(type)
        return false unless submitter?(el)

        emit_submitter(el, data)
        return true
      end
      return false if %w[reset button].include?(type) # never submitted
      if type == "hidden" && !el.has_attribute?("value") &&
         attr(el, "name").to_s.casecmp?("_charset_")
        # A hidden `_charset_` with no `value` reports the submission encoding.
        collect_named(el, @encoding.name, data)
        return false
      end

      case type
      when "checkbox", "radio"
        if el.checked
          value = el.has_attribute?("value") ? el.get_attribute("value") : "on"
          collect_named(el, value, data)
        end
      when "file"
        collect_file(el, data)
      else
        collect_named(el, el.value.to_s, data)
      end
      false
    end

    # Only the clicked submitter button contributes its name/value.
    def collect_button(el, data)
      return false unless submitter?(el)

      emit_submitter(el, data)
      true
    end

    def submitter?(el)
      @submitter && el.__dommy_backend_node__.equal?(@submitter.__dommy_backend_node__)
    end

    # Each File becomes its own entry; an empty file input still contributes an
    # empty File so the field name survives. A File value is kept here even for
    # a non-multipart form — reducing it to its basename is the encoder's (or
    # FormSubmission's) job.
    def collect_file(el, data)
      name = attr(el, "name")
      return if blank?(name)

      files = el.respond_to?(:files) ? el.files : nil
      if files && !files.empty?
        files.each { |file| data.append(name, file) }
      else
        data.append(name, File.new([], "", "type" => "application/octet-stream"))
      end
    end

    def collect_select(el, data)
      name = attr(el, "name")
      return if blank?(name)

      each_node(el.selected_options) do |option|
        next if Internal::ElementState.disabled_element?(option)

        data.append(name, option.value.to_s)
      end
    end

    # Browsers submit textarea values with CRLF line endings.
    def normalize_newlines(value)
      value.gsub(/\r\n|\r|\n/, "\r\n")
    end

    def collect_named(el, value, data)
      name = attr(el, "name")
      data.append(name, value) unless blank?(name)
    end

    # Fallback when the submitter is not among the form's controls.
    def append_submitter(data)
      return unless @submitter

      emit_submitter(@submitter, data)
    end

    # The submitter's name/value (or image coordinates) join the form data.
    def emit_submitter(el, data)
      if image_submitter?(el)
        # Image buttons submit click coordinates. With no layout we use 0,0.
        prefix = blank?(attr(el, "name")) ? "" : "#{attr(el, "name")}."
        data.append("#{prefix}x", "0")
        data.append("#{prefix}y", "0")
        return
      end

      name = attr(el, "name")
      return if blank?(name)

      data.append(name, attr(el, "value") || "")
    end

    def image_submitter?(el)
      el.tag_name == "INPUT" && el.type == "image"
    end

    # A `dirname` on an auto-directionality text control contributes the
    # element's directionality under the dirname's name (HTML §4.10.19.2).
    def append_dirname(el, data)
      return unless DIRNAME_ELEMENTS.include?(el.tag_name)

      dirname = attr(el, "dirname")
      return if blank?(dirname)
      return unless Internal::Directionality.auto_directionality_form_associated?(el)

      data.append(dirname, Internal::Directionality.direction_of(el))
    end

    # All controls belonging to this form, in document order.
    def controls
      form_id = attr(@form, "id")
      @form.document.query_selector_all("input, textarea, select, button").select do |el|
        if el.has_attribute?("form")
          !blank?(form_id) && el.get_attribute("form") == form_id
        else
          el.closest("form")&.equal?(@form)
        end
      end
    end

    # A control is unsuccessful if it or an ancestor <fieldset> is disabled
    # (a first-legend control is exempt). The rule is shared with the `:disabled`
    # selector so both stay in step.
    def disabled?(el)
      Internal::ElementState.disabled_element?(el)
    end

    # The `constructing entry list` guard: a nested construction (e.g. a
    # formdata listener building another FormData from the same form) does not
    # fire a second event.
    def fire_formdata(data)
      return if @form.instance_variable_get(:@constructing_entry_list)

      @form.instance_variable_set(:@constructing_entry_list, true)
      begin
        @form.dispatch_event(
          FormDataEvent.new("formdata", "formData" => data, "bubbles" => true)
        )
      ensure
        @form.instance_variable_set(:@constructing_entry_list, false)
      end
    end

    def attr(el, name)
      el&.get_attribute(name)
    end

    def blank?(value)
      value.nil? || value.empty?
    end

    def each_node(collection)
      if collection.respond_to?(:each)
        collection.each { |node| yield node }
      else
        collection.length.times { |i| yield collection.item(i) }
      end
    end
  end
end
