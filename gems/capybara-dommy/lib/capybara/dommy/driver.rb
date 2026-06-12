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

      # --- Deterministic-time seam (used by JS runtimes) ---
      #
      # A JS runtime assigns a callable here; the driver invokes it before
      # each DOM read Capybara polls in its synchronize loop (find_css /
      # find_xpath / html / title). The pump is expected to advance Dommy's
      # virtual scheduler a small slice and drain microtasks, so "content
      # appears after a timeout" specs converge without wall-clock sleeps.
      # Installing a pump also flips `wait?` to true, making Capybara retry
      # failed expectations instead of raising immediately. Survives
      # `reset!` (it belongs to the runtime, not to one page session).
      attr_accessor :time_pump

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
        @frame_stack = []
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
        pump!
        rack_session.html
      end

      # The title of the top-level browsing context, even inside a frame
      # (Capybara's #title contract); the current frame's title is #frame_title.
      def title
        pump!
        rack_session.document&.title
      end

      def status_code
        rack_session.status
      end

      def response_headers
        rack_session.headers || {}
      end

      # --- Query (returns Capybara::Dommy::Node arrays) ---

      def find_css(query, **_options)
        pump!
        wrap(document&.query_selector_all(query))
      end

      def find_xpath(query, **_options)
        pump!
        wrap(document&.xpath(query))
      end

      # --- Node-facing seam (keeps the dommy-rack Session API in one place) ---

      # The document queries run against: the innermost switched-to frame's
      # document, or the top-level page when no frame is active.
      def document
        frame_stack.empty? ? rack_session.document : frame_stack.last[:document]
      end

      # --- Frames ---
      # Capybara::Session#switch_to_frame drives these with an iframe element
      # node, :parent, or :top. Frame documents are fetched through the
      # dommy-rack session (sharing cookies); nothing here touches the
      # top-level page state, so current_url / title stay top-level.

      def switch_to_frame(frame)
        case frame
        when :top
          @frame_stack = []
        when :parent
          frame_stack.pop
        else
          frame_stack.push(load_frame(frame.native))
        end
      end

      def frame_url
        frame_stack.empty? ? rack_session.current_url.to_s : frame_stack.last[:url]
      end

      def frame_title
        document&.title
      end

      # --- Focus / keyboard ---

      def active_element
        Node.new(self, document.active_element)
      end

      # Session-level send_keys. Without JavaScript only focus navigation is
      # meaningful, so :tab (the key Capybara's focused: specs use) moves
      # focus through the tab order; other keys are ignored.
      def send_keys(*keys)
        keys.each { |key| focus_next_tabbable if key == :tab }
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
        @frame_stack = []
      end

      def wait?
        !@time_pump.nil?
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

      def pump!
        @time_pump&.call
      end

      def frame_stack
        @frame_stack ||= []
      end

      # Fetch an iframe's document, resolving its src against the enclosing
      # frame's URL so nested frames with relative srcs load correctly.
      def load_frame(iframe_element)
        src = iframe_element.get_attribute("src").to_s
        raise Capybara::Dommy::Error, "iframe has no src" if src.empty?

        url = ::URI.join(frame_url, src).to_s
        response = rack_session.fetch(url, headers: {"Referer" => frame_url})
        doc = response.document
        raise Capybara::Dommy::Error, "iframe did not return an HTML document" unless doc

        {document: doc, url: url}
      end

      # Sequential focus navigation: elements with a positive tabindex first
      # (ascending, document order within a value), then the remaining
      # focusables in document order. The page's tab cycle starts over when
      # the current active element is not in the order (e.g. body).
      FOCUSABLE_SELECTOR = "a[href], button, input, select, textarea, [tabindex]"

      def focus_next_tabbable
        ordered = tab_order
        return if ordered.empty?

        current = document.active_element
        index = ordered.index { |el| el == current }
        target = ordered[index ? index + 1 : 0]
        target&.focus
      end

      def tab_order
        candidates = document.query_selector_all(FOCUSABLE_SELECTOR).to_a.reject do |el|
          el.get_attribute("tabindex").to_s.start_with?("-") ||
            el.has_attribute?("disabled") ||
            el.get_attribute("type").to_s.downcase == "hidden" ||
            !visible?(el)
        end
        positive, natural = candidates.each_with_index.partition { |el, _i| el.get_attribute("tabindex").to_i.positive? }
        positive.sort_by { |el, i| [el.get_attribute("tabindex").to_i, i] }.map(&:first) + natural.map(&:first)
      end

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
