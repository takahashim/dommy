# frozen_string_literal: true

module Capybara
  module Dommy
    # Process-wide defaults for new drivers. `Driver.new` falls back to these
    # when a keyword argument is omitted.
    class Configuration
      attr_accessor :default_host, :follow_redirects, :max_redirects, :visibility,
                    :raise_on_unsupported_js

      def initialize
        @default_host = "http://example.org"
        @follow_redirects = true
        @max_redirects = 5
        @visibility = :html
        @raise_on_unsupported_js = true
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
