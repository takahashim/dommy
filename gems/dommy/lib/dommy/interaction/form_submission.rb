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

      # Returns { method:, url:, params:, enctype:, target: }.
      def submit!
        method = form_method
        params = reduce_files(entry_list.entries)
        method = apply_method_override(method, params)
        params = normalize_line_endings(params)
        params = apply_charset(params)

        {
          method: method,
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
        @entry_list ||= Dommy::FormEntryList.new(
          @form, submitter: @submitter, encoding: form_charset || Encoding::UTF_8
        ).form_data
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
        return pairs if charset.nil? || charset == Encoding::UTF_8

        pairs.map { |name, value| [encode_in(name, charset), encode_in(value, charset)] }
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

      # Byte string in `charset`, with each code point the charset cannot
      # represent emitted as `&#N;` (and a lone surrogate as U+FFFD).
      def encode_string(value, charset)
        source = value.valid_encoding? ? value : value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        source.each_codepoint.each_with_object(+"".b) do |code_point, out|
          char = code_point_char(code_point)
          if char.nil?
            out << "&#65533;" # a lone surrogate is U+FFFD
            next
          end

          begin
            out << char.encode(charset).b
          rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
            out << "&##{code_point};"
          end
        end
      end

      def code_point_char(code_point)
        code_point.chr(Encoding::UTF_8)
      rescue RangeError
        nil
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
