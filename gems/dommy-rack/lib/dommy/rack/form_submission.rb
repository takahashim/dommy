# frozen_string_literal: true

module Dommy
  module Rack
    # Collects successful form controls and resolves the effective method,
    # action, and enctype for a form submission. Stateless given the form,
    # submitter, and session config — it returns a plain data hash and does
    # not make any requests itself.
    class FormSubmission
      FORM_URLENCODED = "application/x-www-form-urlencoded"
      MULTIPART = "multipart/form-data"
      OVERRIDE_METHODS = %w[PATCH PUT DELETE].freeze

      def initialize(form, submitter, config)
        @form = form
        @submitter = submitter
        @config = config
      end

      # Returns { method:, url:, params:, enctype: }.
      def submit!
        method = form_method
        params = collect_params
        method = apply_method_override(method, params)
        params = apply_charset(params)

        {
          method: method,
          url: resolve_action(form_method),
          params: params,
          enctype: form_enctype
        }
      end

      private

      def form_method
        raw = (attr(@submitter, "formmethod") || attr(@form, "method")).to_s.upcase
        %w[GET POST].include?(raw) ? raw : "GET"
      end

      def form_enctype
        attr(@submitter, "formenctype") || attr(@form, "enctype") || FORM_URLENCODED
      end

      # For GET forms the action's existing query string is discarded and
      # replaced by the form data; POST keeps it.
      def resolve_action(method)
        raw = (attr(@submitter, "formaction") || attr(@form, "action") || "").to_s
        method == "GET" ? raw.split("?", 2).first.to_s : raw
      end

      # Returns ordered [name, value] pairs in document order. The clicked
      # submitter is emitted at its document position; only if it isn't among
      # the form's controls do we append it at the end.
      def collect_params
        pairs = []
        submitter_emitted = false
        controls.each do |el|
          next if disabled?(el)

          case el.tag_name
          when "INPUT" then submitter_emitted = true if collect_input(el, pairs)
          when "TEXTAREA" then collect_named(el, normalize_newlines(el.value.to_s), pairs)
          when "SELECT" then collect_select(el, pairs)
          when "BUTTON" then submitter_emitted = true if collect_button(el, pairs)
          end
        end
        append_submitter(pairs) unless submitter_emitted
        pairs
      end

      # Returns true when this input is the clicked submitter (and was emitted).
      def collect_input(el, pairs)
        type = el.type
        if %w[submit image].include?(type)
          return false unless submitter?(el)

          emit_submitter(el, pairs)
          return true
        end
        return false if %w[reset button].include?(type) # never submitted

        case type
        when "checkbox", "radio"
          if el.checked
            value = el.has_attribute?("value") ? el.get_attribute("value") : "on"
            collect_named(el, value, pairs)
          end
        when "file"
          collect_file(el, pairs)
        else
          collect_named(el, el.value.to_s, pairs)
        end
        false
      end

      # Only the clicked submitter button contributes its name/value.
      def collect_button(el, pairs)
        return false unless submitter?(el)

        emit_submitter(el, pairs)
        true
      end

      def submitter?(el)
        @submitter && el.__dommy_backend_node__.equal?(@submitter.__dommy_backend_node__)
      end

      # Each File becomes its own entry. An empty file input still
      # contributes an empty File so the field name survives (HTML spec).
      def collect_file(el, pairs)
        name = attr(el, "name")
        return if blank?(name)

        files = el.respond_to?(:files) ? el.files : nil

        unless multipart?
          # Non-multipart forms submit only the file's basename, per browsers.
          filename = files && !files.empty? ? files.first.name.to_s : ""
          pairs << [name, ::File.basename(filename)]
          return
        end

        if files && !files.empty?
          files.each { |file| pairs << [name, file] }
        else
          pairs << [name, Dommy::File.new([], "", "type" => "application/octet-stream")]
        end
      end

      def multipart?
        form_enctype == MULTIPART
      end

      def collect_select(el, pairs)
        name = attr(el, "name")
        return if blank?(name)

        each_node(el.selected_options) do |option|
          pairs << [name, option.value.to_s]
        end
      end

      # Browsers submit textarea values with CRLF line endings.
      def normalize_newlines(value)
        value.gsub(/\r\n|\r|\n/, "\r\n")
      end

      def collect_named(el, value, pairs)
        name = attr(el, "name")
        pairs << [name, value] unless blank?(name)
      end

      # Fallback when the submitter is not among the form's controls.
      def append_submitter(pairs)
        return unless @submitter

        emit_submitter(@submitter, pairs)
      end

      # The submitter's name/value (or image coordinates) join the form data.
      # `formaction`/`formmethod`/`formenctype` are honored elsewhere;
      # `formtarget` is ignored (single session, like `target`) and
      # `formnovalidate` is moot (dommy-rack runs no client-side validation).
      def emit_submitter(el, pairs)
        if image_submitter?(el)
          # Image buttons submit click coordinates. With no layout we use 0,0.
          prefix = blank?(attr(el, "name")) ? "" : "#{attr(el, "name")}."
          pairs << ["#{prefix}x", "0"]
          pairs << ["#{prefix}y", "0"]
          return
        end

        name = attr(el, "name")
        return if blank?(name)

        pairs << [name, attr(el, "value") || ""]
      end

      def image_submitter?(el)
        el.tag_name == "INPUT" && el.type == "image"
      end

      # Honor the form's accept-charset by encoding string values into the
      # requested charset's bytes; urlencoding/multipart then carries them
      # verbatim. Names are assumed ASCII. UTF-8 (the default) is a no-op.
      def apply_charset(pairs)
        charset = form_charset
        return pairs if charset.nil? || charset == Encoding::UTF_8

        pairs.map { |name, value| [name, encode_in(value, charset)] }
      end

      def form_charset
        raw = attr(@form, "accept-charset").to_s
        token = raw.split(/[\s,]+/).find { |t| !t.empty? }
        return nil unless token

        begin
          Encoding.find(token)
        rescue ArgumentError
          nil
        end
      end

      def encode_in(value, charset)
        case value
        when Array then value.map { |v| encode_in(v, charset) }
        when String then encode_string(value, charset)
        else value # File/Blob pass through unchanged
        end
      end

      def encode_string(value, charset)
        value.encode(charset).b
      rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
        value
      end

      def apply_method_override(method, pairs)
        return method unless method == "POST" && @config.respect_method_override

        index = pairs.index { |name, _| name == @config.method_override_param }
        return method unless index

        override = pairs.delete_at(index)[1]
        candidate = override.to_s.upcase
        OVERRIDE_METHODS.include?(candidate) ? candidate : method
      end

      # All controls belonging to this form, in document order: descendants
      # without a `form` attribute, plus any element anywhere associated to
      # this form by `form="<this form's id>"`. Scanning the whole document
      # once keeps them in document order (matters for param ordering).
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

      # A control is unsuccessful if it or an ancestor <fieldset> is disabled.
      def disabled?(el)
        return true if el.has_attribute?("disabled")

        fieldset = el.closest("fieldset")
        fieldset ? fieldset.has_attribute?("disabled") : false
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
end
