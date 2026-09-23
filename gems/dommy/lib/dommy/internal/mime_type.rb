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

      # Every parameter, as [lowercased name, value] pairs in source order.
      def parameters(mime_type)
        mime_type.to_s.scan(PARAMETER).map do |key, quoted, bare|
          [key.downcase, quoted ? quoted.gsub(/\\(.)/, '\1') : bare.to_s.strip]
        end
      end
    end
  end
end
