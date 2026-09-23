# frozen_string_literal: true

module Dommy
  module Internal
    # Reading a MIME type's parameters.
    #
    # It is not an encoding concern, which is where `charset` extraction used to
    # live — in Dommy::Encodings, because that is where the caller happened to
    # need it. A parameter list is MIME grammar, and getting it wrong is how a
    # boundary containing `;charset=` came to be read as a charset.
    #
    # Spec: https://mimesniff.spec.whatwg.org/#parsing-a-mime-type
    module MimeType
      # A parameter value is either a quoted string, in which a `;` is ordinary
      # text, or a run of characters up to the next `;`. Anchoring on the
      # semicolon that STARTS a parameter — rather than scanning for the name
      # anywhere — is what keeps a quoted value from being mistaken for one.
      PARAMETER = /;\s*([^\s;=]+)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]*))/

      module_function

      # The value of `name` among the MIME type's parameters, or nil. The name
      # is ASCII case-insensitive; a quoted value comes back unquoted.
      def parameter(mime_type, name)
        wanted = name.to_s.downcase
        parameters(mime_type).each do |key, value|
          return value if key == wanted
        end
        nil
      end

      # The charset parameter, or nil.
      def charset_of(mime_type) = parameter(mime_type, "charset")

      # The MIME type with its `charset` parameter's value replaced, or
      # unchanged when it has no charset. A splice, not a re-serialization: a
      # header the author wrote comes back as they wrote it apart from the one
      # value that is being corrected, quotes and spacing included.
      def with_charset(mime_type, value)
        text = mime_type.to_s
        range = charset_value_range(text)
        return text unless range

        text.dup.tap { |out| out[range] = value }
      end

      # Every parameter, as [lowercased name, value] pairs in source order.
      def parameters(mime_type)
        mime_type.to_s.scan(PARAMETER).map do |key, quoted, bare|
          [key.downcase, quoted ? quoted.gsub(/\\(.)/, '\1') : bare.to_s.strip]
        end
      end

      # Where the charset parameter's value sits in the source text, inside the
      # quotes when it is quoted. Found by walking the parameter list rather
      # than searching for "charset=", so a `;charset=` inside some other
      # parameter's quoted value is not mistaken for the parameter itself — the
      # same rule that #parameters follows.
      def charset_value_range(text)
        found = nil
        text.scan(PARAMETER) do
          match = Regexp.last_match
          next unless match[1].casecmp?("charset")

          group = match[2] ? 2 : 3
          found = (match.begin(group)...match.end(group))
          break
        end
        found
      end
      private_class_method :charset_value_range
    end
  end
end
