# frozen_string_literal: true

require_relative "test_helper"

# Round out EventTarget coverage with the remaining happy-dom edges:
# TypeError on non-Event, multiple bindings with `once`, listener
# scope, and arbitrary on* keys.
class TestEventTargetExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_dispatch_event_raises_for_non_event
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event("not-an-event") }
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event({}) }
  end

  def test_dispatch_event_raises_for_nil
    # WebIDL: dispatchEvent takes a non-nullable Event, so null is a TypeError
    # rather than a silent no-op.
    assert_raises(Dommy::Bridge::TypeError) { @btn.dispatch_event(nil) }
  end

  def test_dispatch_event_raises_for_an_uninitialized_event
    event = @doc.create_event("Event")
    assert_raises(Dommy::DOMException::InvalidStateError) { @btn.dispatch_event(event) }
    event.__js_call__("initEvent", ["ready", true, false])
    assert_equal(true, @btn.dispatch_event(event))
  end

  def test_once_option_fires_once_then_removes
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"once" => true})
    @btn.click
    @btn.click
    @btn.click
    assert_equal(1, count)
  end

  def test_once_with_multiple_distinct_listeners
    fired = []
    @btn.add_event_listener("click", proc { fired << :a }, {"once" => true})
    @btn.add_event_listener("click", proc { fired << :b }, {"once" => true})
    @btn.click
    assert_equal([:a, :b], fired)
    @btn.click
    # both auto-removed
    assert_equal([:a, :b], fired)
  end

  # WebIDL reads the `once` boolean with ToBoolean: 0 and "" are false.
  def test_once_uses_js_truthiness
    count = 0
    @btn.add_event_listener("click", proc { count += 1 }, {"once" => 0})
    @btn.add_event_listener("click", proc { count += 10 }, {"once" => ""})
    @btn.click
    @btn.click
    assert_equal(22, count)
  end

  # A `signal` that is not an AbortSignal cannot be converted, so the call
  # throws before anything is added; an undefined one is as if missing.
  def test_a_signal_must_be_an_abort_signal
    fired = []
    [nil, "signal", {}].each do |signal|
      assert_raises(Dommy::Bridge::TypeError) do
        @btn.add_event_listener("click", proc { fired << signal }, {"signal" => signal})
      end
    end
    @btn.add_event_listener("click", proc { fired << :undefined }, {"signal" => Dommy::Bridge::UNDEFINED})
    @btn.click
    assert_equal([:undefined], fired)
  end

  def test_an_on_name_no_interface_declares_is_not_an_event_handler
    # HTML §8.1.8.1: only the event handler IDL attributes an interface
    # declares are handlers. `el.oncustom = fn` is an ordinary property, so a
    # dispatched "custom" event does not run it, and the name is case-sensitive.
    seen = []
    assert_equal(Dommy::Bridge::UNHANDLED, @btn.__js_set__("oncustom", proc { seen << :custom }))
    assert_equal(Dommy::Bridge::UNHANDLED, @btn.__js_set__("onClick", proc { seen << :click }))
    @btn.dispatch_event(Dommy::Event.new("custom"))
    @btn.click
    assert_empty(seen)
    assert_equal(Dommy::Bridge::ABSENT, @btn.__js_get__("oncustom"))
  end

  def test_a_declared_handler_fires
    seen = []
    @btn.__js_set__("onclick", proc { seen << :click })
    @btn.click
    assert_equal([:click], seen)
    refute_nil(@btn.__js_get__("onclick"))
  end

  def test_throwing_listener_is_isolated_and_dispatch_continues
    # WHATWG: a listener's exception is reported and dispatch keeps going — it
    # must not escape dispatch_event (a synthetic click from the host would
    # otherwise crash). The later listener still fires.
    fired = []
    @btn.add_event_listener("click", proc { fired << :first })
    @btn.add_event_listener("click", proc { raise "boom" })
    @btn.add_event_listener("click", proc { fired << :third })
    assert_equal(true, @btn.dispatch_event(Dommy::Event.new("click")))
    assert_equal(%i[first third], fired)
  end

  def test_custom_event_listener_via_constructor
    seen_detail = nil
    @btn.add_event_listener("ping", proc { |e| seen_detail = e.__js_get__("detail") })
    @btn.dispatch_event(Dommy::CustomEvent.new("ping", "detail" => "hi"))
    assert_equal("hi", seen_detail)
  end

  def test_remove_event_listener_with_unknown_listener_is_noop
    @btn.remove_event_listener("click", proc { })
    # No exception, no crash.
    assert(true)
  end

  def test_remove_event_listener_unknown_type_is_noop
    @btn.remove_event_listener("never-registered", proc { })
    assert(true)
  end
end

# HTML event handlers, with a Ruby stand-in for the engine's compiler: an
# `on*` content attribute's handler is activated when the attribute is set (or,
# for one a parser set, at boot or when an event first reaches the element),
# compiled when first read or run, and keeps its place in the listener list
# however its value changes.
class TestEventHandlerAttributes < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @compiled = []
    @ran = []
    @doc.event_handler_compiler = lambda do |element, name, source, window_handler|
      raise Dommy::Bridge::ThrowValue.new("SyntaxError") if source == "}"

      @compiled << [element&.local_name, name, source, window_handler]
      ran = @ran
      proc { ran << source }
    end
    @el = @doc.create_element("div")
    @doc.body.append_child(@el)
  end

  def click(target = @el) = target.dispatch_event(Dommy::Event.new("click", "bubbles" => true))

  def listener(label) = proc { @ran << label }

  def test_set_attribute_activates_and_compiles_lazily
    @el.set_attribute("onclick", "a()")
    assert_empty @compiled
    click
    assert_equal [["div", "onclick", "a()", false]], @compiled
    assert_equal ["a()"], @ran
  end

  # The listener is added when the handler first gets a value and keeps its
  # position when the value changes.
  def test_the_handler_keeps_its_position
    @el.add_event_listener("click", listener("one"))
    @el.set_attribute("onclick", "first()")
    @el.add_event_listener("click", listener("three"))
    @el.__js_set__("onclick", listener("two"))
    click
    assert_equal %w[one two three], @ran
  end

  def test_null_deactivates_and_a_new_value_goes_last
    @el.set_attribute("onclick", "first()")
    @el.add_event_listener("click", listener("one"))
    @el.__js_set__("onclick", nil)
    @el.__js_set__("onclick", listener("two"))
    click
    assert_equal %w[one two], @ran
  end

  # EventHandler is [LegacyTreatNonObjectAsNull].
  def test_a_non_object_value_is_null
    @el.__js_set__("onclick", "a()")
    assert_nil @el.__js_get__("onclick")
    @el.__js_set__("onclick", 42)
    assert_nil @el.__js_get__("onclick")
  end

  def test_removing_the_attribute_deactivates_only_when_it_was_there
    @el.__js_set__("onclick", listener("idl"))
    @el.remove_attribute("onclick")
    click
    assert_equal ["idl"], @ran

    @el.set_attribute("onclick", "attr()")
    @el.remove_attribute("onclick")
    @ran.clear
    click
    assert_empty @ran
  end

  # A body that does not compile makes the value null (reported), without
  # deactivating the handler: a later value takes the same place.
  def test_a_compile_error_keeps_the_position
    @el.add_event_listener("click", listener("one"))
    @el.set_attribute("onclick", "}")
    @el.add_event_listener("click", listener("three"))
    assert_nil @el.__js_get__("onclick")
    @el.__js_set__("onclick", listener("two"))
    click
    assert_equal %w[one two three], @ran
  end

  # The parser runs no attribute change steps: a parsed element's handlers
  # are activated when an event first reaches it, once.
  def test_parsed_handlers_activate_on_first_dispatch
    @el.inner_html = "<span onclick='parsed()'></span>"
    span = @el.first_element_child
    click(span)
    click(span)
    assert_equal %w[parsed() parsed()], @ran
    assert_equal 1, @compiled.size
  end

  def test_a_parsed_handler_nulled_by_script_stays_null
    @el.inner_html = "<span onclick='parsed()'></span>"
    span = @el.first_element_child
    @doc.__internal_activate_parsed_event_handlers__
    span.__js_set__("onclick", nil)
    @doc.__internal_activate_parsed_event_handlers__
    click(span)
    assert_empty @ran
  end

  # On body, a Window-reflecting handler is the Window's: compiled without
  # the element in scope, and onerror with the five-argument form.
  def test_body_reflected_handlers_belong_to_the_window
    @doc.body.set_attribute("onload", "loaded()")
    @doc.body.set_attribute("onerror", "failed()")
    refute_nil @win.__js_get__("onload")
    refute_nil @win.__js_get__("onerror")
    assert_equal [[nil, "onload", "loaded()", true], [nil, "onerror", "failed()", true]], @compiled
    @win.dispatch_event(Dommy::Event.new("load"))
    assert_equal ["loaded()"], @ran
  end

  def test_no_compiler_means_no_handler
    @doc.event_handler_compiler = nil
    @el.set_attribute("onclick", "a()")
    assert_nil @el.__js_get__("onclick")
    click
    assert_empty @ran
  end
end

# Events the user agent fires are trusted.
class TestUserAgentEventsAreTrusted < Minitest::Test
  include DommyTestHelper

  def record(target, type, log)
    target.add_event_listener(type, ->(e) { log << [type, e.__js_get__("isTrusted")] })
  end

  def test_document_lifecycle_events
    win = make_window
    doc = win.document
    log = []
    record(doc, "readystatechange", log)
    record(doc, "DOMContentLoaded", log)
    record(win, "load", log)
    doc.__internal_set_ready_state__("loading")
    doc.__internal_set_ready_state__("interactive")
    doc.__internal_set_ready_state__("complete")
    assert_equal [["readystatechange", true]] * 2 + [["DOMContentLoaded", true], ["readystatechange", true], ["load", true]],
                 log.values_at(0, 1, 2, 3, 4)
  end

  def test_reported_exceptions_and_rejections
    win = make_window
    log = []
    record(win, "error", log)
    record(win, "unhandledrejection", log)
    record(win, "rejectionhandled", log)
    win.__internal_report_exception__(RuntimeError.new("x"), "x")
    win.__internal_report_rejection__("r")
    win.__internal_report_rejection_handled__("r")
    assert_equal [["error", true], ["unhandledrejection", true], ["rejectionhandled", true]], log
  end

  # The special error handler rule (five arguments, `true` cancels) is for an
  # ErrorEvent; a plain `error` Event at the window is an ordinary handler call.
  def test_special_error_handler_only_for_an_error_event
    win = make_window
    seen = []
    win.__js_set__("onerror", ->(*args) { seen << args.size; true })
    plain = Dommy::Event.new("error", {"cancelable" => true})
    win.dispatch_event(plain)
    refute plain.default_prevented?
    error_event = Dommy::ErrorEvent.new("error", {"cancelable" => true, "message" => "m"})
    win.dispatch_event(error_event)
    assert error_event.default_prevented?
    assert_equal [1, 5], seen
  end

  # OnBeforeUnloadEventHandler: a non-null return cancels and becomes
  # returnValue when that is still empty.
  def test_beforeunload_handler_return_value
    win = make_window
    win.__js_set__("onbeforeunload", ->(_e) { "leave?" })
    event = Dommy::BeforeUnloadEvent.new("beforeunload", {"cancelable" => true})
    win.dispatch_event(event)
    assert event.default_prevented?
    assert_equal "leave?", event.return_value

    win.__js_set__("onbeforeunload", ->(_e) { nil })
    event = Dommy::BeforeUnloadEvent.new("beforeunload", {"cancelable" => true})
    win.dispatch_event(event)
    refute event.default_prevented?
  end

end

class TestDefaultPassiveListeners < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  # DOM "default passive value": touchstart/touchmove/wheel/mousewheel
  # listeners on a Window, a Document, the document element or the body are
  # passive unless their options say otherwise; elsewhere they are not.
  def test_default_passive_value
    prevented = lambda do |target, type, options = nil|
      target.add_event_listener(type, proc { |e| e.__js_call__("preventDefault", []) }, options)
      event = Dommy::Event.new(type, {"cancelable" => true})
      target.dispatch_event(event)
      event.default_prevented?
    end
    refute prevented.call(@win, "wheel")
    refute prevented.call(@doc, "touchstart")
    refute prevented.call(@doc.document_element, "touchmove")
    refute prevented.call(@doc.body, "mousewheel")
    assert prevented.call(@btn, "wheel")
    assert prevented.call(@win, "click")
    assert prevented.call(@doc.body, "wheel", {"passive" => false})
  end
end
