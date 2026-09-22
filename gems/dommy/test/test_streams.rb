# frozen_string_literal: true

require_relative "test_helper"

class TestStreamsSpec < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  # Run every microtask and immediately-due task that is queued.
  def drain
    8.times { @win.scheduler.advance_time(0) }
  end

  def state_of(promise)
    promise.instance_variable_get(:@state)
  end

  def value_of(promise)
    promise.instance_variable_get(:@value)
  end

  def readable_from(*chunks)
    Dommy::ReadableStream.new(@win, {
      "start" => proc do |controller|
        chunks.each { |chunk| controller.enqueue(chunk) }
        controller.close
      end
    })
  end

  # --- ReadableStream --------------------------------------------------------

  def test_pull_is_called_while_the_queue_is_below_the_high_water_mark
    pulls = 0
    stream = Dommy::ReadableStream.new(@win, {
      "pull" => proc do |controller|
        pulls += 1
        controller.enqueue(pulls)
      end
    }, {"highWaterMark" => 3})
    drain
    assert_equal(3, pulls)
    reader = stream.get_reader
    assert_equal(1, reader.read.await["value"])
    drain
    assert_equal(4, pulls) # the read made room for one more
  end

  def test_a_read_on_an_empty_stream_waits_for_the_next_enqueue
    controller = nil
    stream = Dommy::ReadableStream.new(@win, {"start" => proc { |c| controller = c }})
    reader = stream.get_reader
    read = reader.read
    drain
    assert_equal(:pending, state_of(read))
    controller.enqueue("late")
    assert_equal({"value" => "late", "done" => false}, read.await)
  end

  def test_close_delivers_the_queue_then_done_and_settles_closed
    stream = readable_from("a")
    reader = stream.get_reader
    assert_equal("a", reader.read.await["value"])
    assert_equal({"value" => Dommy::Bridge::UNDEFINED, "done" => true}, reader.read.await)
    assert_nil(reader.closed.await)
    assert_equal(:closed, stream.state)
  end

  def test_error_rejects_reads_and_closed
    stream = Dommy::ReadableStream.new(@win, {"start" => proc { |c| c.error(Dommy::Bridge::TypeError.new("boom")) }})
    reader = stream.get_reader
    error = assert_raises(Dommy::Bridge::TypeError) { reader.read.await }
    assert_equal("boom", error.message)
    assert_raises(Dommy::Bridge::TypeError) { reader.closed.await }
    assert_equal(:errored, stream.state)
  end

  def test_a_start_that_throws_errors_the_stream
    stream = Dommy::ReadableStream.new(@win, {"start" => proc { raise Dommy::Bridge::TypeError, "no" }})
    assert_raises(Dommy::Bridge::TypeError) { stream.get_reader.read.await }
  end

  def test_cancel_runs_the_source_cancel_and_closes
    cancelled = nil
    stream = Dommy::ReadableStream.new(@win, {
      "start" => proc { |c| c.enqueue("x") },
      "cancel" => proc { |reason| cancelled = reason }
    })
    stream.cancel("why").await
    assert_equal("why", cancelled)
    assert_equal(:closed, stream.state)
    assert_equal(true, stream.get_reader.read.await["done"])
  end

  def test_the_lock_and_release_lock
    controller = nil
    stream = Dommy::ReadableStream.new(@win, {"start" => proc { |c| controller = c; c.enqueue("a") }})
    reader = stream.get_reader
    assert(stream.locked)
    assert_raises(Dommy::Bridge::TypeError) { stream.get_reader }
    assert_raises(Dommy::Bridge::TypeError) { stream.cancel.await }
    assert_equal("a", reader.read.await["value"])
    pending = reader.read
    reader.release_lock
    refute(stream.locked)
    assert_raises(Dommy::Bridge::TypeError) { pending.await } # a read left waiting is rejected
    assert_raises(Dommy::Bridge::TypeError) { reader.read.await }
    controller.enqueue("b")
    assert_equal("b", stream.get_reader.read.await["value"])
  end

  def test_desired_size_follows_the_strategy
    controller = nil
    Dommy::ReadableStream.new(@win, {"start" => proc { |c| controller = c }},
                              {"highWaterMark" => 10, "size" => proc { |chunk| chunk.length }})
    assert_equal(10, controller.desired_size)
    controller.enqueue("abcd")
    assert_equal(6, controller.desired_size)
  end

  def test_a_bad_chunk_size_errors_the_stream
    controller = nil
    stream = Dommy::ReadableStream.new(@win, {"start" => proc { |c| controller = c }},
                                       {"size" => proc { |_chunk| -1 }})
    assert_raises(Dommy::Bridge::RangeError) { controller.enqueue("a") }
    assert_equal(:errored, stream.state)
  end

  def test_tee_gives_both_branches_every_chunk_and_cancels_the_source_once_both_are_cancelled
    cancelled = false
    stream = Dommy::ReadableStream.new(@win, {
      "start" => proc { |c| c.enqueue("a"); c.enqueue("b"); c.close },
      "cancel" => proc { cancelled = true }
    })
    left, right = stream.tee
    assert(stream.locked)
    assert_equal("a", left.get_reader.read.await["value"])
    right_reader = right.get_reader
    assert_equal("a", right_reader.read.await["value"])
    assert_equal("b", right_reader.read.await["value"])
    assert_equal(true, right_reader.read.await["done"])

    stream = Dommy::ReadableStream.new(@win, {
      "start" => proc { |c| c.enqueue("x") },
      "cancel" => proc { cancelled = true }
    })
    left, right = stream.tee
    left_cancel = left.cancel # settles only once the other branch is cancelled too
    drain
    refute(cancelled)
    assert_equal(:pending, state_of(left_cancel))
    right.cancel.await
    assert(cancelled)
    assert_nil(left_cancel.await)
  end

  # --- WritableStream --------------------------------------------------------

  def test_sink_writes_run_one_at_a_time_in_order
    order = []
    stream = Dommy::WritableStream.new(@win, {
      "write" => proc { |chunk| order << "write #{chunk}" },
      "close" => proc { order << "close" }
    })
    writer = stream.get_writer
    writer.write("a")
    writer.write("b")
    assert_empty(order) # nothing until the microtask that starts the stream
    closed = writer.close
    assert_nil(closed.await)
    assert_equal(["write a", "write b", "close"], order)
    assert_equal(:closed, stream.state)
    assert_nil(writer.closed.await)
  end

  def test_a_slow_sink_holds_the_next_write
    releases = []
    stream = Dommy::WritableStream.new(@win, {
      "write" => proc do |_chunk|
        promise = Dommy::PromiseValue.new(@win)
        releases << promise
        promise
      end
    })
    writer = stream.get_writer
    first = writer.write("a")
    second = writer.write("b")
    drain
    assert_equal(1, releases.length)
    assert_equal(:pending, state_of(first))
    releases[0].fulfill(nil)
    assert_nil(first.await)
    drain
    assert_equal(2, releases.length)
    assert_equal(:pending, state_of(second))
  end

  def test_ready_waits_out_backpressure
    releases = []
    stream = Dommy::WritableStream.new(@win, {
      "write" => proc do |_chunk|
        promise = Dommy::PromiseValue.new(@win)
        releases << promise
        promise
      end
    }, {"highWaterMark" => 1})
    writer = stream.get_writer
    assert_equal(1, writer.desired_size)
    assert_nil(writer.ready.await)
    writer.write("a")
    assert_equal(0, writer.desired_size)
    drain
    assert_equal(:pending, state_of(writer.ready))
    releases[0].fulfill(nil)
    assert_nil(writer.ready.await)
    assert_equal(1, writer.desired_size)
  end

  def test_a_sink_write_that_rejects_errors_the_stream
    stream = Dommy::WritableStream.new(@win, {"write" => proc { raise Dommy::Bridge::TypeError, "sink broke" }})
    writer = stream.get_writer
    first = writer.write("a")
    second = writer.write("b")
    assert_raises(Dommy::Bridge::TypeError) { first.await }
    assert_raises(Dommy::Bridge::TypeError) { second.await }
    assert_raises(Dommy::Bridge::TypeError) { writer.closed.await }
    assert_equal(:errored, stream.state)
    assert_nil(writer.desired_size)
    assert_raises(Dommy::Bridge::TypeError) { writer.write("c").await }
  end

  def test_abort_rejects_pending_writes_and_runs_the_sink_abort
    aborted = nil
    stream = Dommy::WritableStream.new(@win, {
      "write" => proc { Dommy::PromiseValue.new(@win) },
      "abort" => proc { |reason| aborted = reason }
    })
    writer = stream.get_writer
    write = writer.write("a")
    drain
    assert_nil(writer.abort("stop").await)
    assert_equal("stop", aborted)
    assert_raises(RuntimeError) { write.await } # rejected with the reason, a plain string
    assert_equal("stop", value_of(write))
    assert_equal(:errored, stream.state)
  end

  def test_writes_after_close_are_rejected
    stream = Dommy::WritableStream.new(@win, {})
    writer = stream.get_writer
    writer.close
    assert_raises(Dommy::Bridge::TypeError) { writer.write("late").await }
    assert_raises(Dommy::Bridge::TypeError) { writer.close.await }
  end

  def test_the_writer_lock_and_release
    stream = Dommy::WritableStream.new(@win, {})
    writer = stream.get_writer
    assert(stream.locked)
    assert_raises(Dommy::Bridge::TypeError) { stream.get_writer }
    writer.release_lock
    refute(stream.locked)
    assert_raises(Dommy::Bridge::TypeError) { writer.write("x").await }
    assert_raises(Dommy::Bridge::TypeError) { writer.closed.await }
    assert_nil(stream.get_writer.close.await)
  end

  def test_queuing_strategies
    assert_equal(4, Dommy::ByteLengthQueuingStrategy.byte_length(Dommy::Bridge::Bytes.new([1, 2, 3, 4])))
    stream = Dommy::WritableStream.new(@win, {"write" => proc { Dommy::PromiseValue.new(@win) }},
                                       Dommy::ByteLengthQueuingStrategy.new({"highWaterMark" => 8}))
    writer = stream.get_writer
    writer.write("abc")
    assert_equal(5, writer.desired_size)
    assert_equal(1, Dommy::CountQueuingStrategy.new({"highWaterMark" => 2}).__js_get__("size").call("anything"))
  end

  # --- TransformStream -------------------------------------------------------

  def test_transform_and_flush
    stream = Dommy::TransformStream.new(@win, {
      "transform" => proc { |chunk, controller| controller.enqueue(chunk.upcase) },
      "flush" => proc { |controller| controller.enqueue("end") }
    })
    writer = stream.writable.get_writer
    reader = stream.readable.get_reader
    writer.write("a")
    writer.close
    assert_equal("A", reader.read.await["value"])
    assert_equal("end", reader.read.await["value"])
    assert_equal(true, reader.read.await["done"])
  end

  def test_the_identity_transform_and_a_write_that_waits_for_a_read
    stream = Dommy::TransformStream.new(@win)
    writer = stream.writable.get_writer
    reader = stream.readable.get_reader
    write = writer.write("x")
    drain
    assert_equal(:pending, state_of(write)) # the readable side has not asked yet
    assert_equal("x", reader.read.await["value"])
    assert_nil(write.await)
  end

  def test_a_transform_that_throws_errors_both_sides
    stream = Dommy::TransformStream.new(@win, {
      "transform" => proc { raise Dommy::Bridge::TypeError, "bad chunk" }
    })
    writer = stream.writable.get_writer
    reader = stream.readable.get_reader
    write = writer.write("x")
    read = reader.read
    assert_raises(Dommy::Bridge::TypeError) { read.await }
    assert_raises(Dommy::Bridge::TypeError) { write.await }
    assert_raises(Dommy::Bridge::TypeError) { writer.closed.await }
    assert_raises(Dommy::Bridge::TypeError) { reader.closed.await }
  end

  def test_terminate_closes_the_readable_and_errors_the_writable
    controller = nil
    stream = Dommy::TransformStream.new(@win, {"start" => proc { |c| controller = c }})
    reader = stream.readable.get_reader
    writer = stream.writable.get_writer
    controller.terminate
    assert_equal(true, reader.read.await["done"])
    assert_raises(Dommy::Bridge::TypeError) { writer.write("x").await }
  end

  def test_cancelling_the_readable_errors_the_writable
    stream = Dommy::TransformStream.new(@win)
    writer = stream.writable.get_writer
    stream.readable.cancel("gone").await
    write = writer.write("x")
    assert_raises(RuntimeError) { write.await }
    assert_equal("gone", value_of(write))
  end

  # --- piping ------------------------------------------------------------------

  def test_pipe_to_carries_chunks_and_closes_the_destination
    out = []
    closed = false
    dest = Dommy::WritableStream.new(@win, {"write" => proc { |chunk| out << chunk }, "close" => proc { closed = true }})
    assert_nil(readable_from("a", "b", "c").pipe_to(dest).await)
    assert_equal(%w[a b c], out)
    assert(closed)
    refute(dest.locked)
  end

  def test_pipe_to_with_prevent_close_leaves_the_destination_open
    dest = Dommy::WritableStream.new(@win, {})
    readable_from("a").pipe_to(dest, {"preventClose" => true}).await
    assert_equal(:writable, dest.state)
  end

  def test_pipe_to_propagates_a_source_error_by_aborting_the_destination
    aborted = nil
    dest = Dommy::WritableStream.new(@win, {"abort" => proc { |reason| aborted = reason }})
    source = Dommy::ReadableStream.new(@win, {"start" => proc { |c| c.enqueue("a"); c.error("broken") }})
    pipe = source.pipe_to(dest)
    assert_raises(RuntimeError) { pipe.await }
    assert_equal("broken", value_of(pipe))
    assert_equal("broken", aborted)
    assert_equal(:errored, dest.state)
  end

  def test_pipe_to_propagates_a_destination_error_by_cancelling_the_source
    cancelled = nil
    source = Dommy::ReadableStream.new(@win, {
      "pull" => proc { |c| c.enqueue("more") },
      "cancel" => proc { |reason| cancelled = reason }
    })
    dest = Dommy::WritableStream.new(@win, {"write" => proc { raise Dommy::Bridge::TypeError, "full" }})
    pipe = source.pipe_to(dest)
    assert_raises(Dommy::Bridge::TypeError) { pipe.await }
    assert_kind_of(Dommy::Bridge::TypeError, cancelled)
    assert_equal(:closed, source.state)
  end

  def test_pipe_through_returns_the_transform_readable
    upper = Dommy::TransformStream.new(@win, {"transform" => proc { |chunk, c| c.enqueue(chunk.upcase) }})
    out = []
    readable_from("a", "b").pipe_through(upper).pipe_to(
      Dommy::WritableStream.new(@win, {"write" => proc { |chunk| out << chunk }})
    ).await
    assert_equal(%w[A B], out)
  end

  def test_pipe_to_refuses_a_locked_stream
    source = readable_from("a")
    source.get_reader
    assert_raises(Dommy::Bridge::TypeError) { source.pipe_to(Dommy::WritableStream.new(@win, {})).await }
  end

  # --- the text and compression streams ride on TransformStream -------------

  def test_text_decoder_stream_holds_a_split_sequence_and_flushes_the_rest
    out = []
    source = readable_from(Dommy::Bridge::Bytes.new([0xE3, 0x81]), Dommy::Bridge::Bytes.new([0x82, 0x41]),
                           Dommy::Bridge::Bytes.new([0xE3]))
    source.pipe_through(Dommy::TextDecoderStream.new(@win)).pipe_to(
      Dommy::WritableStream.new(@win, {"write" => proc { |chunk| out << chunk }})
    ).await
    assert_equal(["\u3042A", "\ufffd"], out)
  end

  def test_text_decoder_stream_rejects_a_chunk_that_is_not_bytes
    stream = Dommy::TextDecoderStream.new(@win)
    write = stream.writable.get_writer.write([65])
    read = stream.readable.get_reader.read # the write is only looked at once the readable asks
    assert_raises(Dommy::Bridge::TypeError) { read.await }
    assert_raises(Dommy::Bridge::TypeError) { write.await }
    assert_equal("utf-8", stream.encoding)
    refute(stream.fatal?)
  end

  def test_text_encoder_stream_encodes_and_converts_to_string
    out = []
    readable_from("h\u00e9", 12).pipe_through(Dommy::TextEncoderStream.new(@win)).pipe_to(
      Dommy::WritableStream.new(@win, {"write" => proc { |chunk| out << chunk.to_a }})
    ).await
    assert_equal([[104, 0xC3, 0xA9], [49, 50]], out)
  end

  def test_compression_stream_round_trip_through_pipes
    original = "compress me " * 40
    compressed = []
    readable_from(original).pipe_through(Dommy::CompressionStream.new(@win, "gzip")).pipe_to(
      Dommy::WritableStream.new(@win, {"write" => proc { |chunk| compressed << chunk }})
    ).await
    restored = []
    readable_from(compressed.flatten.pack("C*")).pipe_through(Dommy::DecompressionStream.new(@win, "gzip")).pipe_to(
      Dommy::WritableStream.new(@win, {"write" => proc { |chunk| restored << chunk }})
    ).await
    assert_equal(original, restored.flatten.pack("C*"))
  end
end
