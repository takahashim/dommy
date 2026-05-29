# frozen_string_literal: true

require_relative "test_helper"

# --- Performance (User Timing) -------------------------------------

class TestPerformance < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @perf = @win.__js_get__("performance")
  end

  def test_now_advances_with_scheduler
    t1 = @perf.now
    @win.scheduler.advance_time(50)
    assert_in_delta(50.0, @perf.now - t1, 0.001)
  end

  def test_mark_and_get_entries_by_name
    @perf.mark("phase-1")
    entries = @perf.get_entries_by_name("phase-1")
    assert_equal(1, entries.length)
    assert_equal("mark", entries.first.entry_type)
  end

  def test_measure_uses_marks
    @perf.mark("start")
    @win.scheduler.advance_time(120)
    @perf.mark("end")
    @perf.measure("dur", "start", "end")
    measured = @perf.get_entries_by_name("dur").first
    assert_in_delta(120.0, measured.duration, 0.001)
  end

  def test_clear_marks
    @perf.mark("a")
    @perf.mark("b")
    @perf.clear_marks
    assert_empty(@perf.get_entries_by_type("mark"))
  end
end

# --- CookieStore ---------------------------------------------------

class TestCookieStore < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @cs = @win.__js_get__("cookieStore")
  end

  def test_set_and_get_roundtrip
    @cs.set("session", "abc").await
    got = @cs.get("session").await
    assert_equal("abc", got["value"])
  end

  def test_delete_removes
    @cs.set("k", "v").await
    @cs.delete("k").await
    assert_nil(@cs.get("k").await)
  end

  def test_change_event_fires_on_set
    fired = nil
    @cs.add_event_listener("change", proc { |e| fired = e.changed.first["name"] })
    @cs.set("evt", "1").await
    assert_equal("evt", fired)
  end
end

# --- Navigator extras ----------------------------------------------

class TestNavigatorExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @nav = @win.navigator
  end

  def test_share_records_last_payload
    @nav.share({"title" => "hi", "url" => "https://x"}).await
    assert_equal({"title" => "hi", "url" => "https://x"}, @nav.__test_last_shared__)
  end

  def test_vibrate_records_pattern
    @nav.vibrate([100, 50, 200])
    @nav.vibrate(80)
    assert_equal([[100, 50, 200], [80]], @nav.__test_vibration_log__)
  end

  def test_wake_lock_request_returns_sentinel
    sentinel = @nav.wake_lock.request("screen").await
    assert_equal("screen", sentinel.type)
    refute(sentinel.released)
    sentinel.release
    assert(sentinel.released)
  end

  def test_get_battery_returns_manager
    bat = @nav.get_battery.await
    assert_kind_of(Dommy::BatteryManager, bat)
    assert_equal(1.0, bat.level)
    assert(bat.charging)
  end
end

# --- SubtleCrypto HMAC ---------------------------------------------

class TestSubtleCryptoHMAC < Minitest::Test
  include DommyTestHelper

  def setup
    @subtle = make_window.__js_get__("crypto").subtle
  end

  def test_import_key_and_sign_verify_roundtrip
    key = @subtle.import_key("raw", "secret", {"name" => "HMAC", "hash" => "SHA-256"}).await
    sig = @subtle.sign({"name" => "HMAC"}, key, "hello world").await
    assert_kind_of(Array, sig)
    # SHA-256
    assert_equal(32, sig.length)
    assert(@subtle.verify({"name" => "HMAC"}, key, sig, "hello world").await)
  end

  def test_verify_fails_on_tampered_data
    key = @subtle.import_key("raw", "secret", {"name" => "HMAC", "hash" => "SHA-256"}).await
    sig = @subtle.sign({"name" => "HMAC"}, key, "original").await
    refute(@subtle.verify({"name" => "HMAC"}, key, sig, "tampered").await)
  end

  def test_generate_key_produces_unique_keys
    a = @subtle.generate_key({"name" => "HMAC", "hash" => "SHA-256"}).await
    b = @subtle.generate_key({"name" => "HMAC", "hash" => "SHA-256"}).await
    refute_equal(a.__dommy_bytes__, b.__dommy_bytes__)
  end

  def test_explicit_sha512_hash
    key = @subtle.import_key("raw", "k", {"name" => "HMAC", "hash" => "SHA-512"}).await
    sig = @subtle.sign({"name" => "HMAC"}, key, "x").await
    assert_equal(64, sig.length)
  end

  def test_hmac_without_hash_rejects
    # WebCrypto requires an explicit hash; dommy now matches the spec
    # and refuses to silently default to SHA-256.
    assert_raises(ArgumentError) { @subtle.import_key("raw", "k", "HMAC").await }
    assert_raises(ArgumentError) do
      @subtle.import_key("raw", "k", {"name" => "HMAC"}).await
    end
  end
end

# --- Streams -------------------------------------------------------

class TestStreams < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_readable_stream_enqueue_and_read
    stream = Dommy::ReadableStream.new(
      @win,
      {
        "start" => proc { |c|
          c.enqueue("a")
          c.enqueue("b")
          c.close
        }
      }
    )
    reader = stream.get_reader
    assert_equal({"value" => "a", "done" => false}, reader.read.await)
    assert_equal({"value" => "b", "done" => false}, reader.read.await)
    assert_equal({"value" => nil, "done" => true}, reader.read.await)
  end

  def test_writable_stream_invokes_sink_write
    received = []
    stream = Dommy::WritableStream.new(
      @win,
      {
        "write" => proc { |chunk| received << chunk }
      }
    )
    w = stream.get_writer
    w.write("a")
    w.write("b")
    w.close
    assert_equal(%w[a b], received)
  end

  def test_transform_stream_chains
    upper = Dommy::TransformStream.new(
      @win,
      {
        "transform" => proc { |chunk, controller| controller.enqueue(chunk.upcase) }
      }
    )
    w = upper.writable.get_writer
    w.write("foo")
    w.close
    r = upper.readable.get_reader
    assert_equal("FOO", r.read.await["value"])
  end

  def test_text_encoder_stream
    es = Dommy::TextEncoderStream.new(@win)
    w = es.writable.get_writer
    w.write("hello")
    w.close
    bytes = es.readable.get_reader.read.await["value"]
    assert_equal([104, 101, 108, 108, 111], bytes)
  end

  def test_text_decoder_stream
    ds = Dommy::TextDecoderStream.new(@win)
    w = ds.writable.get_writer
    w.write([104, 105])
    w.close
    str = ds.readable.get_reader.read.await["value"]
    assert_equal("hi", str)
  end
end

# --- Compression Streams ------------------------------------------

class TestCompressionStreams < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_gzip_roundtrip
    original = "The quick brown fox" * 50
    compressed = pipe_through(Dommy::CompressionStream.new(@win, "gzip"), original)
    restored = pipe_through(Dommy::DecompressionStream.new(@win, "gzip"), compressed.pack("C*"))
    assert_equal(original, restored.pack("C*"))
  end

  def test_deflate_roundtrip
    original = "deflate me " * 20
    compressed = pipe_through(Dommy::CompressionStream.new(@win, "deflate"), original)
    restored = pipe_through(Dommy::DecompressionStream.new(@win, "deflate"), compressed.pack("C*"))
    assert_equal(original, restored.pack("C*"))
  end

  def test_unsupported_format_raises
    assert_raises(ArgumentError) { Dommy::CompressionStream.new(@win, "lz4") }
  end

  private

  def pipe_through(stream, input)
    w = stream.writable.get_writer
    w.write(input)
    w.close
    stream.readable.get_reader.read.await["value"]
  end
end

# --- Worker (inline) ----------------------------------------------

class TestWorker < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
  end

  def test_post_message_round_trips_via_handler
    w = Dommy::Worker.new(@win, "echo.js")
    w.__test_on_message__ { |msg| w.__test_post_to_main__("echo: #{msg["data"]}") }
    received = nil
    w.add_event_listener("message", proc { |e| received = e.data })
    w.post_message("hello")
    @win.scheduler.drain_microtasks
    @win.scheduler.drain_microtasks
    assert_equal("echo: hello", received)
  end

  def test_terminate_blocks_further_messages
    w = Dommy::Worker.new(@win, "x.js")
    received = nil
    w.__test_on_message__ { |_msg| received = "got it" }
    w.terminate
    w.post_message("hi")
    @win.scheduler.drain_microtasks
    assert_nil(received)
  end

  def test_window_exposes_constructor
    ctor = @win.__js_get__("Worker")
    w = ctor.__js_new__(["worker.js"])
    assert_kind_of(Dommy::Worker, w)
  end
end
