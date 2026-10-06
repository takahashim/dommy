# frozen_string_literal: true

require_relative "test_helper"

# HTML's script processing model as Dommy runs it without a JS engine: the
# document's script_runner stands in for one, so what gets prepared, when, and
# with which currentScript is observable from Ruby.
class TestScriptElementProcessing < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @ran = []
    @doc.script_runner = lambda do |source|
      current = @doc.__js_get__("currentScript")
      @ran << [source, current&.get_attribute("id")]
      @nested&.call(source)
    end
  end

  def script(text = nil, **attrs)
    @doc.create_element("script").tap do |s|
      attrs.each { |name, value| s.set_attribute(name.to_s, value) }
      s.text_content = text if text
    end
  end

  def sources = @ran.map(&:first)

  # "prepare the script element" types a script from `type`, or from
  # `language` when there is no type: every JavaScript MIME type essence match
  # is classic; the rest never run.
  def test_script_type_determination
    {
      {} => :classic,
      {type: ""} => :classic,
      {type: "text/javascript1.5"} => :classic,
      {type: "application/x-javascript"} => :classic,
      {type: "TEXT/JSCRIPT"} => :classic,
      {type: " text/javascript "} => :classic,
      {type: "text/javascript; charset=utf-8"} => nil,
      {type: "module"} => :module,
      {type: "Module"} => :module,
      {type: " module"} => nil,
      {type: "importmap"} => :importmap,
      {type: "speculationrules"} => :speculationrules,
      {type: "application/json"} => nil,
      {language: "javascript1.2"} => :classic,
      {language: "livescript"} => :classic,
      {language: ""} => :classic,
      {language: "vbscript"} => nil,
      {type: "", language: "vbscript"} => :classic,
      {type: "text/plain", language: "javascript"} => nil
    }.each do |attrs, expected|
      actual = script(**attrs).__internal_script_type__
      expected.nil? ? assert_nil(actual, attrs.inspect) : assert_equal(expected, actual, attrs.inspect)
    end
  end

  def test_inserted_classic_scripts_run_with_current_script_set_and_restored
    @doc.body.append_child(script("a()", id: "outer"))
    assert_equal [["a()", "outer"]], @ran
    assert_nil @doc.__js_get__("currentScript")
  end

  # A script inserted and run from inside another leaves the outer one current
  # again afterwards (the old value is restored, not null).
  def test_nested_execution_restores_the_outer_current_script
    @nested = lambda do |source|
      next unless source == "outer()"

      @doc.body.append_child(script("inner()", id: "inner"))
      @ran << ["after", @doc.__js_get__("currentScript")&.get_attribute("id")]
    end
    @doc.body.append_child(script("outer()", id: "outer"))
    assert_equal [["outer()", "outer"], ["inner()", "inner"], ["after", "outer"]], @ran
  end

  def test_current_script_is_null_inside_a_shadow_tree
    host = @doc.create_element("div")
    @doc.body.append_child(host)
    host.attach_shadow("mode" => "open").append_child(script("s()", id: "shadowed"))
    assert_equal [["s()", nil]], @ran
  end

  # An empty script is not started: given text later, it runs. Whitespace is
  # not empty, so a whitespace-only script runs (as nothing) and is spent.
  def test_empty_script_runs_when_given_children_later
    empty = script(id: "empty")
    @doc.body.append_child(empty)
    assert_empty @ran
    empty.append_child(@doc.create_text_node("late()"))
    assert_equal ["late()"], sources

    blank = script("  ")
    @doc.body.append_child(blank)
    blank.text_content = "never()"
    assert_equal ["late()", "  "], sources
  end

  def test_removing_a_child_does_not_prepare_a_script
    s = script("x()", type: "0")
    @doc.body.append_child(s)
    div = @doc.create_element("div")
    s.append_child(div)
    s.set_attribute("type", "")
    div.remove
    assert_empty @ran
  end

  def test_a_script_of_unknown_type_is_not_started
    s = script("x()", type: "text/plain")
    @doc.body.append_child(s)
    assert_empty @ran
    s.set_attribute("type", "text/javascript")
    @doc.body.append_child(s) # re-inserting prepares it again
    assert_equal ["x()"], sources
  end

  # `nomodule` stops a classic script, but it has started all the same.
  def test_nomodule_classic_script_does_not_run_and_is_started
    s = script("x()", nomodule: "")
    @doc.body.append_child(s)
    s.remove_attribute("nomodule")
    @doc.body.append_child(s)
    assert_empty @ran
    assert s.__internal_script_already_started__
  end

  def test_event_for_legacy_scripts
    @doc.body.append_child(script("a()", event: "onload", for: "window"))
    @doc.body.append_child(script("b()", event: "onclick", for: "window"))
    @doc.body.append_child(script("c()", event: "onload()", for: " WINDOW "))
    @doc.body.append_child(script("d()", event: "onload", for: "document"))
    assert_equal ["a()", "c()"], sources
  end

  # Setting `src` on a connected script that has not started prepares it.
  def test_setting_src_prepares_a_connected_script
    external = []
    @doc.external_script_runner = ->(element, src) { external << [element.get_attribute("id"), src] }
    s = script(id: "late")
    @doc.body.append_child(s)
    s.set_attribute("src", "/late.js")
    @win.scheduler.advance_time(0)
    assert_equal [["late", "http://localhost/late.js"]], external
  end

  # A dynamically inserted module script runs in a task of its own, through
  # the external runner (which knows it is a module from its prepared state).
  def test_inserted_module_scripts_run_as_a_task
    external = []
    @doc.external_script_runner = lambda do |element, src|
      external << [element.__internal_prepared_script__.type, element.__internal_prepared_script__.source, src]
    end
    @doc.body.append_child(script("m()", type: "module"))
    assert_empty external
    @win.scheduler.advance_time(0)
    assert_equal [[:module, "m()", nil]], external
  end

  # An empty src fails the script: an `error` event, queued.
  def test_empty_src_queues_an_error_event
    @doc.external_script_runner = ->(*) { flunk "nothing to fetch" }
    s = script(src: "")
    events = []
    s.add_event_listener("error", ->(e) { events << [e.type, e.__js_get__("isTrusted")] })
    @doc.body.append_child(s)
    assert_empty events
    @win.scheduler.advance_time(0)
    assert_equal [["error", true]], events
  end

  def test_supports
    assert Dommy::HTMLScriptElement.supports("classic")
    assert Dommy::HTMLScriptElement.supports("module")
    assert Dommy::HTMLScriptElement.supports("importmap")
    refute Dommy::HTMLScriptElement.supports("Module")
    refute Dommy::HTMLScriptElement.supports("text/javascript")
    refute Dommy::HTMLScriptElement.supports(" classic")
  end
end
