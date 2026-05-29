# frozen_string_literal: true

require "securerandom"

module Dommy
  module Rack
    # Encodes collected form params (ordered [name, value] pairs) as a
    # multipart/form-data body. File/Blob values become file parts; other
    # values become text parts. Owns the multipart serialization so the HTTP
    # layer (not Dommy::FormData) is responsible for it.
    module FileUpload
      MIME_TYPES = {
        ".txt" => "text/plain",
        ".html" => "text/html",
        ".htm" => "text/html",
        ".json" => "application/json",
        ".csv" => "text/csv",
        ".xml" => "application/xml",
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".pdf" => "application/pdf"
      }.freeze

      module_function

      # Guess a MIME type from a file path's extension.
      def mime_type_for(path)
        MIME_TYPES.fetch(::File.extname(path).downcase, "application/octet-stream")
      end

      # True when any pair value is a File/Blob.
      def multipart?(pairs)
        return false unless pairs

        pairs.any? { |(_name, value)| value.respond_to?(:__dommy_bytes__) }
      end

      # Returns [body (ASCII-8BIT String), content_type with boundary].
      def encode(pairs, boundary = nil)
        boundary ||= "----DommyRackBoundary#{SecureRandom.hex(16)}"
        body = +"".b
        pairs.each { |name, value| body << part(boundary, name, value) }
        body << "--#{boundary}--\r\n"
        [body, "multipart/form-data; boundary=#{boundary}"]
      end

      def part(boundary, name, value)
        head = +"--#{boundary}\r\n"
        if value.respond_to?(:__dommy_bytes__) # File / Blob
          filename = value.respond_to?(:name) ? value.name.to_s : ""
          content_type = file_content_type(value)
          head << %(Content-Disposition: form-data; name="#{escape(name)}"; filename="#{escape(filename)}"\r\n)
          head << "Content-Type: #{content_type}\r\n\r\n"
          head.b << value.__dommy_bytes__ << "\r\n".b
        else
          head << %(Content-Disposition: form-data; name="#{escape(name)}"\r\n\r\n)
          head.b << value.to_s.dup.force_encoding(Encoding::ASCII_8BIT) << "\r\n".b
        end
      end

      def file_content_type(value)
        type = value.respond_to?(:type) ? value.type.to_s : ""
        type.empty? ? "application/octet-stream" : type
      end

      def escape(str)
        str.to_s.gsub('"', "%22").gsub(/[\r\n]/, "")
      end
    end
  end
end
