# frozen_string_literal: true

require "fileutils"

module Capybara
  module Dommy
    # A Capybara driver backed by Dommy::Rack::Session. Implements the
    # navigation / query / reset! parts of the Capybara::Driver::Base contract;
    # element interaction lives in Capybara::Dommy::Node. The JS-enabled mode
    # additionally supplies deterministic native dialog responses for Capybara's
    # alert/confirm/prompt helpers. Screenshot and window methods remain with
    # Driver::Base (which raises Capybara::NotSupportedByDriverError).
    class Driver < Capybara::Driver::Base
      VISIBILITY_MODES = %i[all html none].freeze

      # A 1x1 transparent PNG. There are no pixels to paint, but the path a
      # screenshot is asked to save must still hold a valid image: Rails'
      # screenshot helper reads it back for its inline / artifact output.
      BLANK_PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==".unpack1("m").freeze

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
                     visibility: nil,
                     javascript: nil)
        super()
        config = Capybara::Dommy.configuration
        @app = app
        @javascript = javascript.nil? ? config.javascript : javascript
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
        if @javascript
          @session_options[:javascript] = true
          # Everything Capybara does reaches the session through a checkpoint
          # already — a query pumps the clock, a node interaction drains, and
          # reset! disposes — so strictness needs no driver-side checks, just
          # this flag. A JS error then surfaces at the next Capybara command,
          # like a server error under raise_server_errors.
          @session_options[:strict_js_errors] = config.raise_js_errors
        end
        # A JS session needs the virtual clock pumped inside Capybara's
        # synchronize loop, so waiting expectations converge on timer/fetch
        # driven updates. A host-installed pump (the documented seam) wins.
        @time_pump ||= -> { @rack_session&.advance_time(16) } if @javascript
      end

      # Whether this driver runs page JavaScript (`javascript: true`, backed by
      # a `Dommy::Rack::Session.new(app, javascript: true)`). Node interactions
      # then dispatch real DOM events (Turbo/Stimulus handlers run) instead of
      # the HTML-only fast paths.
      def javascript? = @javascript

      # Drain the JS runtime after an interaction's events (promise reactions
      # settle before the next Capybara step). No-op without JavaScript.
      def drain_js
        rack_session.after_interaction if @javascript
        nil
      end

      # Suppress strict-mode failure for JS errors raised inside the block, for
      # a spec that triggers one deliberately. Reaching for `page.driver` is the
      # documented exception to keeping specs driver-agnostic: suppressing an
      # error is inherently driver-specific. A page that handles its own errors
      # (`window.onerror` + preventDefault) needs nothing here.
      def allow_js_errors(&block)
        return yield unless @javascript

        rack_session.allow_js_errors(&block)
      end

      # The dommy-rack session. Named `rack_session` to avoid colliding with
      # Capybara::Driver::Base#session (the owning Capybara::Session). Rebuilt
      # when the effective host (Capybara app_host / default_host) changes so
      # current_url reflects it and same-origin checks pass.
      def rack_session
        host = effective_host
        if @rack_session.nil? || @rack_session_host != host
          @rack_session&.dispose
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
        # Capybara polls current_url for have_current_path. In JS mode that poll
        # must advance the virtual clock too: Turbo/fetch continuations often
        # settle in a scheduled task rather than the interaction's microtask
        # drain. The Rack session's History hook then reflects pushState in its
        # current URL.
        pump!
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

      # There is no rendering surface to capture, so a "screenshot" saves the
      # page itself: the serialized HTML and its visible text next to `path`,
      # plus a valid blank image at `path`. Rails' take_failed_screenshot calls
      # this for every failed system test, and letting it raise (the
      # Driver::Base default) would mask the real failure.
      def save_screenshot(path, **_options)
        path = path.to_s
        dir = ::File.dirname(path)
        base = ::File.basename(path, ".*")
        ::FileUtils.mkdir_p(dir)
        ::File.binwrite(path, BLANK_PNG)
        ::File.write(::File.join(dir, "#{base}.html"), html.to_s)
        ::File.write(::File.join(dir, "#{base}.txt"), screenshot_text)
        path
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
        @rack_session&.dispose
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

      # Arguments become the script's `arguments`; a Capybara node argument
      # crosses as its Dommy element (a JS proxy), so
      # `execute_script("arguments[0].scrollIntoView()", node)` works. A runtime
      # that cannot pass arguments raises (see Session#execute_script), rather
      # than silently dropping them.
      def execute_script(script, *args)
        return unsupported_js!("execute_script") unless @javascript

        rack_session.execute_script(script, *unwrap_script_args(args))
      end

      def evaluate_script(script, *args)
        return unsupported_js!("evaluate_script") unless @javascript

        rack_session.evaluate_script(script, *unwrap_script_args(args))
      end

      def evaluate_async_script(_script, *_args)
        unsupported_js!("evaluate_async_script")
      end

      # --- Native dialogs ---
      #
      # A native dialog is synchronous in Dommy, so installing the expected
      # answer before the triggering block runs is sufficient. What is expected,
      # what it answers and what it saw instead live in ModalExpectation; the
      # stack they sit on, which is the session's dialog handler while a helper
      # block is running, is ModalStack.

      def accept_modal(type, **options, &block)
        respond_to_modal(type, accept: true, **options, &block)
      end

      def dismiss_modal(type, **options, &block)
        respond_to_modal(type, accept: false, **options, &block)
      end

      # Visibility decision used by Node#visible?. :all / :none treat every
      # element as visible; :html defers to dommy-rack's HTML-level check.
      def visible?(element)
        return true if @visibility == :all || @visibility == :none

        ::Dommy::Rack.visible?(element)
      end

      private

      # Advance the virtual clock a slice inside Capybara's retry loop, then
      # report whatever the page's JavaScript left unhandled while it ran.
      #
      # The check belongs here rather than only in the session because a JS
      # runtime may install its own pump (the documented `time_pump` seam), and
      # that pump drives the runtime directly instead of going through
      # `Session#advance_time` — so a timer that throws during a poll would
      # otherwise sit in the ledger until some later command happened to check.
      def pump!
        @time_pump&.call
        rack_session.check_js_errors! if @javascript
      end

      def frame_stack
        @frame_stack ||= []
      end

      # A frame's document: its `srcdoc` when present (Dommy builds it from
      # the attribute, so there is nothing to fetch), else its `src` resolved
      # against the enclosing frame's URL so nested relative srcs load
      # correctly.
      def load_frame(iframe_element)
        if (doc = srcdoc_document(iframe_element))
          return {document: doc, url: frame_url}
        end

        src = iframe_element.get_attribute("src").to_s
        raise Capybara::Dommy::Error, "iframe has no src" if src.empty?

        url = ::URI.join(frame_url, src).to_s
        response = rack_session.fetch(url, headers: {"Referer" => frame_url})
        doc = response.document
        raise Capybara::Dommy::Error, "iframe did not return an HTML document" unless doc

        {document: doc, url: url}
      end

      # The document Dommy already built for a `srcdoc` frame (its URL is
      # about:srcdoc, with the base URL inherited from the enclosing
      # document); nil when the frame has no `srcdoc`.
      def srcdoc_document(iframe_element)
        srcdoc = iframe_element.get_attribute("srcdoc")
        return nil if srcdoc.nil?

        return iframe_element.content_document if iframe_element.respond_to?(:content_document) && iframe_element.content_document

        Dommy.parse(srcdoc).document
      end

      def screenshot_text
        doc = document
        return "" unless doc

        TextExtractor.new(self).visible_text(doc.body)
      rescue StandardError
        ""
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
        options&.app_host || options&.default_host || @session_options[:default_host]
      end

      def owning_session_options
        session_options if session
      rescue StandardError
        nil
      end

      def wrap(elements)
        (elements || []).map { |element| Node.new(self, element) }
      end

      # A script argument: a Capybara node becomes the Dommy element it wraps
      # (so it crosses to JS as a proxy), anything else passes through. Arrays
      # are mapped so a list of nodes works too.
      def unwrap_script_args(args)
        args.map do |arg|
          case arg
          when Node then arg.native
          when Array then unwrap_script_args(arg)
          else arg
          end
        end
      end

      def unsupported_js!(name)
        return nil unless @raise_on_unsupported_js

        raise Capybara::NotSupportedByDriverError,
              "capybara-dommy does not support JavaScript (#{name})"
      end

      def respond_to_modal(type, accept:, text: nil, with: nil, **_options)
        expectation = ModalExpectation.new(type: type, accept: accept, text: text, with: with)
        modals.push(expectation)
        rack_session.dialog_handler = modals
        yield if block_given?

        raise Capybara::ModalNotFound, expectation.not_found_message unless expectation.answered?

        expectation.message
      ensure
        if expectation
          modals.delete(expectation)
          rack_session.dialog_handler = nil if modals.empty? && @rack_session
        end
      end

      def modals
        @modals ||= ModalStack.new
      end
    end
  end
end
