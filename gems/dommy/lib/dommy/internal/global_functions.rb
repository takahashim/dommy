# frozen_string_literal: true

require "cgi"
require "erb"

module Dommy
  module Internal
    # Stateless global functions exposed on the JS global (Window) that don't
    # depend on any window state. Kept here so Window doesn't carry the cgi/erb
    # dependency just for URI component encoding.
    module GlobalFunctions
      module_function

      # JS `encodeURIComponent`: percent-encode everything except
      # `A-Za-z0-9 - _ . ! ~ * ' ( )`. `ERB::Util.url_encode` matches this,
      # unlike `CGI.escape` (which uses `+` for space).
      def encode_uri_component(value)
        ERB::Util.url_encode(value.to_s)
      end

      def decode_uri_component(value)
        CGI.unescape(value.to_s)
      end
    end
  end
end
