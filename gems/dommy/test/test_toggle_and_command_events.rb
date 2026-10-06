# frozen_string_literal: true

require_relative "test_helper"

# ToggleEvent and CommandEvent (HTML §"The ToggleEvent interface", §"The
# CommandEvent interface"): an `Element?` source in the init dictionary, read
# back retargeted against the event's currentTarget.
class TestToggleAndCommandEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div><div id='plain'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @root = @host.attach_shadow("mode" => "open")
    @inner = @doc.create_element("button")
    @root.append_child(@inner)
  end

  def test_toggle_event_init
    event = Dommy::ToggleEvent.new("toggle", "oldState" => "closed", "newState" => "open", "source" => @inner)
    assert_equal "closed", event.old_state
    assert_equal "open", event.new_state
    # Outside any dispatch the source is retargeted against null: the host.
    assert_same @host, event.source
  end

  def test_source_must_be_an_element
    assert_raises(Dommy::Bridge::TypeError) { Dommy::ToggleEvent.new("toggle", "source" => @doc) }
    assert_nil Dommy::ToggleEvent.new("toggle", "source" => nil).source
  end

  def test_source_is_retargeted_against_the_current_target
    seen = {}
    @root.add_event_listener("command", proc { |e| seen[:inside] = e.source })
    @doc.body.add_event_listener("command", proc { |e| seen[:outside] = e.source })
    event = Dommy::CommandEvent.new("command", "command" => "--go", "source" => @inner,
      "bubbles" => true, "composed" => true)
    @inner.dispatch_event(event)
    assert_same @inner, seen[:inside]
    assert_same @host, seen[:outside]
    assert_equal "--go", event.command
  end
end
