# frozen_string_literal: true

require_relative "test_helper"

# HTML §2.7 safe passing of structured data, as far as Ruby sees it: a message
# is serialized when posted (Dommy.structured_serialize) and deserialized afresh
# where it is delivered; MessagePorts are transferable. The JS realm's own
# serializer (cycles, BigInt, transfer of ArrayBuffers, DataCloneError) is
# covered by WPT html/webappapis/structured-clone and webmessaging.
class TestStructuredSerialization < Minitest::Test
  include DommyTestHelper

  def test_serialize_then_deserialize_gives_a_fresh_copy_each_time
    src = {"k" => [1, {"n" => "x"}]}
    serialized = Dommy.structured_serialize(src)
    a = Dommy.structured_deserialize(serialized)
    b = Dommy.structured_deserialize(serialized)
    assert_equal(src, a)
    refute_same(src, a)
    refute_same(a, b)
    src["k"] << 2
    assert_equal([1, {"n" => "x"}], a["k"], "the snapshot was taken at serialization")
  end

  def test_an_already_serialized_value_passes_through
    serialized = Dommy.structured_serialize("x")
    assert_same(serialized, Dommy.structured_serialize(serialized))
    assert_nil(Dommy.structured_deserialize(nil))
  end

  def test_serializable_platform_objects_clone_their_data
    blob = Dommy::Blob.new(["abc"], {"type" => "text/plain"})
    copy = blob.__internal_structured_clone__
    refute_same(blob, copy)
    assert_equal([3, "text/plain", "abc"], [copy.size, copy.type, copy.text])

    file = Dommy::File.new(["z"], "a.txt", {"lastModified" => 42})
    file_copy = file.__internal_structured_clone__
    assert_equal(["a.txt", 42], [file_copy.name, file_copy.last_modified])

    error = Dommy::DOMException.new("boom", "DataCloneError")
    error_copy = error.__internal_structured_clone__
    assert_equal(["DataCloneError", "boom", 25], [error_copy.name, error_copy.message, error_copy.code])
  end

  def test_message_event_keeps_a_false_data
    assert_equal(false, Dommy::MessageEvent.new("message", "data" => false).data)
  end
end

class TestMessagePortTransfer < Minitest::Test
  include DommyTestHelper

  def test_messages_held_until_start_arrive_in_a_later_task_in_order
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    got = []
    mc.port2.add_event_listener("message", proc { |e| got << e.data })
    mc.port1.post_message(1)
    mc.port1.post_message(2)
    win.scheduler.advance_time(0)
    assert_empty(got, "the port message queue starts disabled")
    mc.port2.start
    assert_empty(got, "start() enables the queue; delivery is a task")
    mc.port1.post_message(3)
    win.scheduler.advance_time(0)
    assert_equal([1, 2, 3], got)
  end

  def test_transfer_detaches_and_hands_over_the_entanglement_and_queue
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    mc.port1.post_message("queued")
    win.scheduler.advance_time(0)

    receiver = mc.port2.__internal_transfer__
    assert(mc.port2.__internal_detached__?)
    assert_raises(Dommy::DOMException::DataCloneError) { mc.port2.__internal_transfer__ }

    got = []
    receiver.add_event_listener("message", proc { |e| got << e.data })
    mc.port1.post_message("after")
    receiver.start
    win.scheduler.advance_time(0)
    assert_equal(%w[queued after], got)
  end

  def test_a_message_in_flight_follows_the_transferred_port
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    mc.port1.post_message("in flight")
    receiver = mc.port2.__internal_transfer__
    got = []
    receiver.add_event_listener("message", proc { |e| got << e.data })
    receiver.start
    win.scheduler.advance_time(0)
    assert_equal(["in flight"], got)
  end

  def test_close_disentangles_both_ends
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    got = []
    mc.port1.add_event_listener("message", proc { |e| got << e.data })
    mc.port1.start
    mc.port1.close
    mc.port2.post_message("lost")
    win.scheduler.advance_time(0)
    assert_empty(got)
    assert(mc.port1.__internal_detached__?)
  end

  def test_message_events_are_trusted
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    trusted = nil
    mc.port2.add_event_listener("message", proc { |e| trusted = e.__js_get__("isTrusted") })
    mc.port2.start
    mc.port1.post_message("x")
    win.scheduler.advance_time(0)
    assert_equal(true, trusted)
  end
end

class TestWindowPostMessage < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.location.__internal_set_url__("https://example.test/page")
  end

  def deliver(target_origin)
    got = nil
    @win.add_event_listener("message", proc { |e| got = e })
    @win.__js_call__("postMessage", [{"a" => 1}, target_origin])
    @win.scheduler.advance_time(0)
    got
  end

  def test_star_and_own_origin_deliver_with_origin_and_source
    event = deliver("*")
    assert_equal({"a" => 1}, event.data)
    assert_equal("https://example.test", event.origin)
    assert_same(@win, event.source)
    refute_nil(deliver("/"))
    refute_nil(deliver("https://example.test"))
  end

  def test_another_target_origin_drops_the_message
    assert_nil(deliver("https://other.test"))
  end
end

class TestBroadcastChannelClosed < Minitest::Test
  include DommyTestHelper

  def test_post_message_on_a_closed_channel_throws
    win = make_window
    channel = Dommy::BroadcastChannel.new(win, "c")
    channel.close
    assert_raises(Dommy::DOMException::InvalidStateError) { channel.post_message("x") }
  end
end
