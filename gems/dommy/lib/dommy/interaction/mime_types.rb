# frozen_string_literal: true

module Dommy
  module Interaction
    # Minimal extension -> MIME type map for guessing a file's content type
    # from its name. Shared by FieldInteractor#attach_file (the JS-enabled
    # path) and dommy-rack's FileUpload / capybara-dommy's Node#attach_file
    # (the Rack-driven paths), which all need the same guess and previously
    # each carried their own copy of this table.
    module MimeTypes
      TYPES = {
        ".txt" => "text/plain", ".html" => "text/html", ".htm" => "text/html",
        ".json" => "application/json", ".csv" => "text/csv", ".xml" => "application/xml",
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif" => "image/gif", ".pdf" => "application/pdf"
      }.freeze

      module_function

      def for(path)
        TYPES.fetch(::File.extname(path.to_s).downcase, "application/octet-stream")
      end
    end
  end
end
