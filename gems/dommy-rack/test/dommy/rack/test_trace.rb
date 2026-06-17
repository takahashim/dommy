# frozen_string_literal: true

require "test_helper"
require "support/null_runtime"

module Dommy
  module Rack
    # Core timeline: request / redirect / document / action / form, plus
    # filtering, levels, and formatters — all without a JS engine.
    class TraceTest < Minitest::Test
      include RackTestHelper

      def test_records_action_http_and_document_in_order
        app = app_for("GET /hello" => html_response(
          "<html><head><title>Hi</title></head><body><h1>Hello</h1></body></html>"
        ))
        session = Session.new(app, trace: true)
        session.visit "/hello"

        assert_equal %i[action http document], session.trace.events.map(&:type)

        http = session.trace.http.first
        assert_equal "GET", http.data[:method]
        assert_equal "/hello", http.data[:path]
        assert_equal 200, http.data[:status]

        assert_equal "Hi", session.trace.documents.first.data[:title]
      end

      def test_action_groups_following_events
        app = app_for("GET /x" => html_response("<title>X</title>"))
        session = Session.new(app, trace: true)
        session.visit "/x"

        action = session.trace.actions.first
        assert_equal :visit, action.name
        assert_equal "/x", action.data[:label]
        assert_equal action.seq, session.trace.http.first.action_seq
      end

      def test_redirect_chain_is_successive_http_hops
        app = app_for(
          "GET /a" => [302, {"Location" => "/b"}, []],
          "GET /b" => html_response("<title>B</title>")
        )
        session = Session.new(app, trace: true)
        session.visit "/a"

        hops = session.trace.http
        assert_equal [302, 200], hops.map { |e| e.data[:status] }
        assert_equal "/b", hops.first.data[:location]
        # Only the final HTML response loads a document.
        assert_equal 1, session.trace.documents.size
      end

      def test_form_params_are_filtered
        app = app_for(
          "GET /form" => html_response(
            '<form action="/login" method="post">' \
            '<input name="email"><input name="password" type="password">' \
            '<button type="submit">Go</button></form>'
          ),
          "POST /login" => html_response("<title>In</title>")
        )
        session = Session.new(app, trace: true)
        session.visit "/form"
        session.fill_in "email", with: "a@b.com"
        session.fill_in "password", with: "secret"
        session.click_button "Go"

        form = session.trace.forms.first
        assert_equal "a@b.com", form.data[:params]["email"]
        assert_equal Trace::ParamFilter::FILTERED, form.data[:params]["password"]
        # The form + its POST belong to the click_button action.
        assert_equal :click_button, session.trace.last_action.name
        assert_equal session.trace.last_action.seq, form.action_seq
      end

      def test_off_level_records_nothing
        app = app_for("GET /x" => html_response("<title>X</title>"))
        session = Session.new(app, trace: true, trace_level: :off)
        session.visit "/x"

        assert_empty session.trace.events
      end

      def test_formatters
        app = app_for("GET /hello" => html_response("<title>Hi</title>"))
        session = Session.new(app, trace: true)
        session.visit "/hello"

        text = session.trace.to_text
        assert_match(/ACTION visit "\/hello"/, text)
        assert_match(%r{HTTP GET /hello 200}, text)
      end
    end

    # DOM mutation capture (Phase 2). Driven by mutating the document directly
    # in Ruby and flushing — no JS engine needed.
    class TraceDomTest < Minitest::Test
      include RackTestHelper

      def test_records_summarized_dom_mutations
        app = app_for("GET /" => html_response(
          "<html><head><title>T</title></head><body><ul id='list'></ul></body></html>"
        ))
        session = Session.new(app, trace: true, trace_dom: true)
        session.visit "/"

        list = session.at_css("#list")
        document = session.document
        list.append_child(document.create_element("li"))
        list.append_child(document.create_element("li"))
        session.trace.flush_dom

        mutation = session.trace.dom_mutations.first
        assert_equal :added, mutation.data[:op]
        assert_equal "ul#list", mutation.data[:target]
        # Two same-target/op mutations coalesce into one entry.
        assert_equal 2, mutation.data[:count]
      end
    end

    # JS-realm streams (script / console / js_error) and the document-before-
    # scripts ordering, driven through the SessionRuntime with a stub backend.
    class TraceJsTest < Minitest::Test
      include RackTestHelper

      def setup
        @previous_factory = DommyRackTestSupport::NullRuntimeBackend.install
      end

      def teardown
        DommyRackTestSupport::NullRuntimeBackend.restore(@previous_factory)
      end

      def test_document_marker_precedes_script_entries
        app = app_for("GET /" => html_response(
          "<html><head><title>T</title></head><body><script>__log__:hi</script></body></html>"
        ))
        session = Session.new(app, javascript: true, trace: true)
        session.visit "/"

        document = session.trace.documents.first
        script = session.trace.scripts.first
        assert document.seq < script.seq, "expected :document before :script"
        assert script.data[:ok]
        assert script.data[:inline]

        assert_equal "hi", session.trace.console.first.data[:text]
      end

      def test_js_error_is_recorded
        app = app_for("GET /" => html_response(
          "<html><body><script>__error__:boom</script></body></html>"
        ))
        session = Session.new(app, javascript: true, trace: true)
        session.visit "/"

        assert_equal "boom", session.trace.js_errors.first.data[:message]
      end

      def test_actions_level_drops_realm_streams
        app = app_for("GET /" => html_response(
          "<html><body><script>__log__:hi</script></body></html>"
        ))
        session = Session.new(app, javascript: true, trace: true, trace_level: :actions)
        session.visit "/"

        assert_empty session.trace.scripts
        assert_empty session.trace.console
        refute_empty session.trace.http
      end
    end
  end
end
