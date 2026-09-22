# frozen_string_literal: true

module Capybara
  module Dommy
    # Process-wide defaults for new drivers. `Driver.new` falls back to these
    # when a keyword argument is omitted.
    class Configuration
      attr_accessor :default_host, :follow_redirects, :max_redirects, :visibility,
                    :raise_on_unsupported_js, :javascript, :raise_js_errors

      def initialize
        @default_host = "http://example.org"
        @follow_redirects = true
        @max_redirects = 5
        @visibility = :html
        @raise_on_unsupported_js = true
        @javascript = false
        # Fail an example on JavaScript the page left unhandled, the way
        # Capybara's own raise_server_errors fails one on a server exception.
        # Only a `javascript: true` driver has any JS to fail on, so this is
        # invisible to a suite migrating from rack_test.
        @raise_js_errors = true
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
