# frozen_string_literal: true

module Capybara
  module Dommy
    # A Capybara driver backed by Dommy::Rack::Session. Implements the
    # navigation / query / reset! parts of the Capybara::Driver::Base contract;
    # element interaction lives in Capybara::Dommy::Node. JavaScript, screenshot,
    # window, and modal methods are left to Driver::Base (which raises
    # Capybara::NotSupportedByDriverError).
    class Driver < Capybara::Driver::Base
      VISIBILITY_MODES = %i[all html none].freeze

      attr_reader :app, :visibility

      def initialize(app,
                     default_host: nil,
                     follow_redirects: nil,
                     max_redirects: nil,
                     visibility: nil)
        super()
        config = Capybara::Dommy.configuration
        @app = app
        @visibility = visibility || config.visibility
        unless VISIBILITY_MODES.include?(@visibility)
          raise ArgumentError,
                "unknown visibility mode #{@visibility.inspect} (expected one of #{VISIBILITY_MODES.join(", ")})"
        end
        @raise_on_unsupported_js = config.raise_on_unsupported_js
        @session_options = {
          default_host: default_host || config.default_host,
          follow_redirects: follow_redirects.nil? ? config.follow_redirects : follow_redirects,
          max_redirects: max_redirects || config.max_redirects,
          # Capybara drives a trusted app and legitimately visits multiple
          # hosts (e.g. app_host / multi-server specs), so don't enforce origin.
          enforce_same_origin: false
        }
      end

      # The dommy-rack session. Named `rack_session` to avoid colliding with
      # Capybara::Driver::Base#session (the owning Capybara::Session). Rebuilt
      # when the effective host (Capybara app_host / default_host) changes so
      # current_url reflects it and same-origin checks pass.
      def rack_session
        host = effective_host
        if @rack_session.nil? || @rack_session_host != host
          @rack_session = ::Dommy::Rack::Session.new(@app, **@session_options.merge(default_host: host))
          @rack_session_host = host
        end
        @rack_session
      end

      # --- Navigation ---

      def visit(path)
        # A fresh visit resolves a relative path against the host root (not the
        # current page's directory), matching browser address-bar semantics.
        rack_session.visit(::URI.join("#{effective_host}/", path.to_s).to_s)
      rescue URI::InvalidURIError
        rack_session.visit(path)
      end

      def current_url
        rack_session.current_url.to_s
      end

      def refresh
        rack_session.reload
      end

      def go_back
        rack_session.back
      end

      def go_forward
        rack_session.forward
      end

      # --- Page state ---

      def html
        rack_session.html
      end

      def title
        document&.title
      end

      def status_code
        rack_session.status
      end

      def response_headers
        rack_session.headers || {}
      end

      # --- Query (returns Capybara::Dommy::Node arrays) ---

      def find_css(query, **_options)
        wrap(document&.query_selector_all(query))
      end

      def find_xpath(query, **_options)
        wrap(document&.xpath(query))
      end

      # --- Node-facing seam (keeps the dommy-rack Session API in one place) ---

      def document
        rack_session.document
      end

      def follow_link(element)
        rack_session.click_link_element(element)
      end

      def submit_form(form, submitter:)
        rack_session.submit_form(form, submitter: submitter)
      end

      # --- Lifecycle ---

      def reset!
        @rack_session = nil
      end

      def wait?
        false
      end

      def needs_server?
        false
      end

      # Lets Capybara reload a node when it goes stale (after navigation).
      def invalid_element_errors
        [Capybara::Dommy::StaleElementReferenceError]
      end

      # --- JavaScript (unsupported) ---
      # When raise_on_unsupported_js is false these become no-ops, so tests
      # that incidentally call them don't fail.

      def execute_script(_script, *_args)
        unsupported_js!("execute_script")
      end

      def evaluate_script(_script, *_args)
        unsupported_js!("evaluate_script")
      end

      def evaluate_async_script(_script, *_args)
        unsupported_js!("evaluate_async_script")
      end

      # Visibility decision used by Node#visible?. :all / :none treat every
      # element as visible; :html defers to dommy-rack's HTML-level check.
      def visible?(element)
        return true if @visibility == :all || @visibility == :none

        ::Dommy::Rack.visible?(element)
      end

      private

      # Capybara's app_host (set per-example) wins over default_host; falls
      # back to the host this driver was configured with. Guarded so a
      # standalone driver (no owning Capybara session) still works.
      def effective_host
        options = owning_session_options
        (options && (options.app_host || options.default_host)) || @session_options[:default_host]
      end

      def owning_session_options
        session_options if session
      rescue StandardError
        nil
      end

      def wrap(elements)
        (elements || []).map { |element| Node.new(self, element) }
      end

      def unsupported_js!(name)
        return nil unless @raise_on_unsupported_js

        raise Capybara::NotSupportedByDriverError,
              "capybara-dommy does not support JavaScript (#{name})"
      end
    end
  end
end
