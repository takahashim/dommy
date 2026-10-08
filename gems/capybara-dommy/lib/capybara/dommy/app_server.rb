# frozen_string_literal: true

module Capybara
  module Dommy
    # What stands in for the server Capybara would boot for a browser driver.
    # Capybara runs the app under Puma, which answers any exception with a 500;
    # its middleware also records the exceptions listed in `server_errors`, and
    # the session re-raises those in the test when `raise_server_errors` is on.
    # Here the app runs in the test process, so a reportable error is raised
    # right where it happens, and every other one becomes the 500 Puma sends.
    # A spec that turns raise_server_errors off to visit a page the app fails
    # on then sees the error page, as it does under a browser.
    class AppServer
      # Puma's own response to an exception the app did not handle.
      ERROR_RESPONSE_BODY = "An unhandled lowlevel error occurred. The application logs may have details.\n"

      # `options` returns the owning session's Capybara config, or nil for a
      # standalone driver. It is read per request: specs flip
      # raise_server_errors after the driver exists.
      def initialize(app, &options)
        @app = app
        @options = options
      end

      # Puma rescues everything a request can raise; Interrupt, SystemExit and
      # NoMemoryError are not the app's errors, so they still propagate.
      def call(env)
        @app.call(env)
      rescue StandardError, ScriptError => e
        raise if reportable?(e)

        [500, {"content-type" => "text/plain; charset=utf-8"}, [ERROR_RESPONSE_BODY]]
      end

      private

      # A driver used without a Capybara session reports everything, as
      # Capybara's defaults (raise_server_errors, server_errors = [Exception]) do.
      def reportable?(error)
        options = @options.call
        return true if options.nil?

        options.raise_server_errors && options.server_errors.any? { |klass| error.is_a?(klass) }
      end
    end
  end
end
