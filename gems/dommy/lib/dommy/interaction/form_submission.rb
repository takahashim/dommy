# frozen_string_literal: true

module Dommy
  module Interaction
    # Resolves the effective method, action, enctype, and target for a form
    # submission and collects its entry list through the shared
    # Dommy::FormEntryList — so the `formdata` event fires exactly as it does for
    # `new FormData(form)`. Stateless given the form and submitter: it returns a
    # plain data hash and makes no requests. The host (Rack session) turns the
    # result into navigation; a standalone Browser dispatches a `submit` event
    # instead. Method-override behavior is passed in so core stays Rack-free.
    class FormSubmission
      FORM_URLENCODED = "application/x-www-form-urlencoded"
      MULTIPART = "multipart/form-data"
      TEXT_PLAIN = "text/plain"
      OVERRIDE_METHODS = %w[PATCH PUT DELETE].freeze

      def initialize(form, submitter, respect_method_override: false, method_override_param: "_method")
        @form = form
        @submitter = submitter
        @respect_method_override = respect_method_override
        @method_override_param = method_override_param
      end

      # Returns { method:, method_override:, url:, params:, enctype:, target: },
      # or nil when the form is already constructing its entry list (HTML
      # returns then). `method_override` says the method is a `_method`
      # field's: the request a browser sends is a POST.
      def submit!
        list = entry_list
        return nil if list.nil?

        params = reduce_files(list.entries)
        method = apply_method_override(form_method, params)
        params = normalize_line_endings(params)
        params = apply_charset(params)

        {
          method: method,
          method_override: method != form_method,
          url: resolve_action(form_method),
          params: params,
          enctype: form_enctype,
          target: form_target
        }
      end

      private

      # The form-submission encodings normalize line breaks in names and string
      # values to CRLF; the entry list itself keeps the control's value (a
      # textarea's value is LF). So `new FormData(form)` reports LF while a
      # submitted request carries CRLF, as browsers do.
      def normalize_line_endings(pairs)
        pairs.map do |name, value|
          [normalize_line_ending(name), value.is_a?(String) ? normalize_line_ending(value) : value]
        end
      end

      def normalize_line_ending(value)
        value.gsub(/\r\n|\r|\n/, "\r\n")
      end

      # The entry list, built (and `formdata` fired) with the submission's
      # encoding so a value-less hidden `_charset_` reports the right name.
      def entry_list
        return @entry_list if defined?(@entry_list)

        @entry_list = Dommy::FormEntryList.new(@form, submitter: @submitter, encoding: form_charset).form_data
      end

      # A non-multipart form submits only a file's basename, per browsers. The
      # entry list keeps the File (spec), so reduce it here for the result.
      def reduce_files(pairs)
        return pairs if multipart?

        pairs.map do |name, value|
          next [name, value] unless value.is_a?(Dommy::Blob)

          filename = value.is_a?(Dommy::File) ? value.name : ""
          [name, basename(filename)]
        end
      end

      # A File's name is already a filename, but strip a path if one slipped in.
      # A name with a null byte is path-invalid; browsers keep it verbatim.
      def basename(filename)
        ::File.basename(filename)
      rescue ArgumentError
        filename
      end

      def form_method
        raw = (attr(@submitter, "formmethod") || attr(@form, "method")).to_s.upcase
        %w[GET POST].include?(raw) ? raw : "GET"
      end

      # The form's enctype is an enumerated attribute: matched ASCII
      # case-insensitively, with any other value — including the empty string —
      # falling back to the missing/invalid value default, urlencoded. A
      # submitter's formenctype, when present, is used as-is (even if invalid).
      def form_enctype
        raw = (attr(@submitter, "formenctype") || attr(@form, "enctype")).to_s.downcase(:ascii)
        [MULTIPART, TEXT_PLAIN].include?(raw) ? raw : FORM_URLENCODED
      end

      def multipart?
        form_enctype == MULTIPART
      end

      # The browsing-context target (formtarget on the submitter wins). A host
      # without a frame model treats everything but a named frame like `_self`.
      def form_target
        attr(@submitter, "formtarget") || attr(@form, "target") || ""
      end

      # For GET forms the action's existing query string is discarded and
      # replaced by the form data; POST keeps it.
      def resolve_action(method)
        raw = (attr(@submitter, "formaction") || attr(@form, "action") || "").to_s
        method == "GET" ? raw.split("?", 2).first.to_s : raw
      end

      # HTML's "converting to a list of name-value pairs": encode each name and
      # string value in the submission encoding, replacing any character the
      # encoding cannot represent with a numeric character reference. UTF-8
      # represents every character, so it is a no-op.
      def apply_charset(pairs)
        charset = form_charset
        return pairs if charset == "UTF-8"

        pairs.map { |name, value| [encode_in(name, charset), encode_in(value, charset)] }
      end

      # HTML "pick an encoding for the form": the first `accept-charset` label
      # that names an encoding, else UTF-8 when it has none that does, else
      # (no attribute) the document's character encoding; as an output
      # encoding, so UTF-16 and replacement submit UTF-8.
      #
      # Spec: https://html.spec.whatwg.org/#picking-an-encoding-for-the-form
      def form_charset
        @form_charset ||= begin
          raw = attr(@form, "accept-charset")
          name =
            if raw
              raw.split(/[\t\n\f\r ]+/).filter_map { |label| Encodings.get(label) unless label.empty? }.first || "UTF-8"
            else
              @form.owner_document&.character_encoding || "UTF-8"
            end
          Encodings.output_encoding(name)
        end
      end

      def encode_in(value, charset)
        case value
        when Array then value.map { |v| encode_in(v, charset) }
        when String then Encodings.encode(charset, value.scrub("\u{FFFD}")) { |code_point| "&##{code_point};".bytes }
        else value # File/Blob pass through unchanged
        end
      end

      def apply_method_override(method, pairs)
        return method unless method == "POST" && @respect_method_override

        index = pairs.index { |name, _| name == @method_override_param }
        return method unless index

        override = pairs.delete_at(index)[1]
        candidate = override.to_s.upcase
        OVERRIDE_METHODS.include?(candidate) ? candidate : method
      end

      def attr(el, name)
        el&.__internal_attribute_value__(name)
      end
    end
  end
end
