# frozen_string_literal: true

require "fileutils"

module Dommy
  module Rails
    # Test-integration helper that runs application JavaScript against the real
    # Rails app, bridging request-style specs to the lightweight test browser.
    # Include it in a Minitest test or RSpec example group to get a `browser`
    # (a `javascript: true` Dommy::Rack::Session bound to the Rails Rack app):
    #
    #   browser.visit todos_path
    #   browser.click "li.todo"
    #   assert browser.has_css?("li.todo.is-completed")
    #
    # External `<script>`s and `fetch` resolve through the Rails app itself
    # (Propshaft / Sprockets / controllers), sharing the session cookie jar.
    # The browser is disposed at teardown, and any uncaught JS error / unhandled
    # rejection fails the test (strict by default) unless wrapped in
    # `allow_js_errors`.
    module BrowserSpec
      # Auto-wire teardown: RSpec example groups get an `after` hook (the
      # example is passed so we can save artifacts on failure); Minitest tests
      # use `after_teardown` (defined below).
      def self.included(base)
        base.after { |example| dommy_browser_after(failed: example.exception ? true : false, label: example.full_description) } if base.respond_to?(:after)
      end

      # Minitest teardown hook (no-op outside Minitest).
      def after_teardown
        failed = respond_to?(:failures) && !failures.empty?
        dommy_browser_after(failed: failed, label: (name if respond_to?(:name)))
      ensure
        super if defined?(super)
      end

      # On a failed example, write debugging artifacts (page HTML + trace +
      # visible text) before disposing, then run the normal teardown. Shared by
      # the RSpec and Minitest hooks.
      def dommy_browser_after(failed:, label: nil)
        dommy_save_failure_artifacts(label) if failed && browser_started?
        dommy_browser_teardown
      end

      # The Rack app the browser drives. Defaults to the Rails application;
      # override `dommy_browser_app` to point elsewhere.
      def dommy_browser_app
        return ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application)

        raise "Dommy::Rails::BrowserSpec needs a Rack app: define #dommy_browser_app " \
              "(Rails.application was not available)."
      end

      # Memoized JS-enabled session bound to the app. Lazily requires the
      # dommy-rack + QuickJS integration so the dependency is only needed when a
      # browser spec actually runs.
      def browser
        @dommy_browser ||= begin
          require "dommy/js/quickjs/rack"
          ::Dommy::Rack::Session.new(dommy_browser_app, javascript: true, trace: true, trace_dom: true)
        end
      end

      # Directory failure artifacts are written under (override per host).
      def dommy_failures_dir = ::File.join("tmp", "dommy", "failures")

      def browser_started? = !@dommy_browser.nil?

      # Suppress strict JS-error failure for errors raised inside the block (they
      # stay in `browser.js_errors`). For specs that intentionally trigger one.
      def allow_js_errors
        @dommy_allow_js_errors = true
        yield
      ensure
        dommy_browser_ack_js_errors
      end

      # Dispose the browser and fail if uncaught JS errors were collected. Call
      # from a Minitest #teardown / RSpec after hook (the integration modules
      # wire this automatically).
      def dommy_browser_teardown
        return unless browser_started?

        pending = browser.js_errors[(@dommy_browser_acked || 0)..] || []
        browser.dispose_js
        @dommy_browser = nil
        return if @dommy_allow_js_errors || pending.empty?

        raise dommy_browser_js_error(pending)
      end

      private

      # Write current.html / trace.json / trace.txt / visible-text.txt for a
      # failed example into a per-example directory, so a CI run can surface
      # what the browser saw. Best-effort: a browser without a trace (or any IO
      # error) is skipped silently rather than masking the real failure.
      def dommy_save_failure_artifacts(label)
        return unless browser.respond_to?(:trace) && browser.trace

        dir = ::File.join(dommy_failures_dir, dommy_artifact_slug(label))
        ::FileUtils.mkdir_p(dir)
        ::File.write(::File.join(dir, "current.html"), browser.html.to_s)
        ::File.write(::File.join(dir, "trace.json"), browser.trace.to_json)
        ::File.write(::File.join(dir, "trace.txt"), browser.trace.to_text)
        ::File.write(::File.join(dir, "visible-text.txt"), browser.text.to_s)
        if browser.respond_to?(:debug)
          ::File.write(::File.join(dir, "dom-summary.txt"), browser.debug.dom_summary)
          ::File.write(::File.join(dir, "aria-snapshot.txt"), browser.debug.aria_snapshot)
        end
        dir
      rescue StandardError
        nil
      end

      def dommy_artifact_slug(label)
        slug = label.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        slug.empty? ? "example" : slug[0, 100]
      end

      def dommy_browser_ack_js_errors
        @dommy_browser_acked = browser_started? ? browser.js_errors.length : 0
      end

      def dommy_browser_js_error(errors)
        lines = errors.map { |e| "  #{e.class}: #{e.message}" }
        RuntimeError.new("#{errors.length} uncaught JS error(s) during the spec:\n#{lines.join("\n")}")
      end
    end
  end
end
