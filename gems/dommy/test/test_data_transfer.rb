# frozen_string_literal: true

require_relative "test_helper"

class TestDataTransfer < Minitest::Test
  include DommyTestHelper

  # --- DataTransfer basics -----------------------------------------

  def test_empty_data_transfer
    dt = Dommy::DataTransfer.new
    assert_kind_of(Dommy::FileList, dt.files)
    assert_equal(0, dt.files.length)
    assert_empty(dt.types)
  end

  def test_data_transfer_with_files
    file = Dommy::File.new(["x"], "a.txt", "type" => "text/plain")
    dt = Dommy::DataTransfer.new(files: [file])
    assert_equal(1, dt.files.length)
    assert_same(file, dt.files[0])
  end

  def test_data_transfer_accepts_file_list_directly
    fl = Dommy::FileList.new([Dommy::File.new(["x"], "a")])
    dt = Dommy::DataTransfer.new(files: fl)
    assert_same(fl, dt.files)
  end

  # --- get_data / set_data / types --------------------------------

  def test_set_and_get_data
    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "hello")
    assert_equal("hello", dt.get_data("text/plain"))
  end

  def test_get_data_returns_empty_for_unset_format
    dt = Dommy::DataTransfer.new
    assert_equal("", dt.get_data("text/plain"))
  end

  def test_format_alias_text_maps_to_text_plain
    dt = Dommy::DataTransfer.new
    dt.set_data("text", "hello")
    assert_equal("hello", dt.get_data("text/plain"))
    assert_equal("hello", dt.get_data("text"))
  end

  def test_format_alias_url_maps_to_text_uri_list
    dt = Dommy::DataTransfer.new
    dt.set_data("url", "https://x.test/")
    assert_equal("https://x.test/", dt.get_data("text/uri-list"))
  end

  def test_types_reflects_set_formats
    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "a")
    dt.set_data("text/html", "<b>b</b>")
    assert_equal(%w[text/plain text/html], dt.types)
  end

  def test_clear_data_with_format
    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "a")
    dt.set_data("text/html", "b")
    dt.clear_data("text/plain")
    assert_equal(%w[text/html], dt.types)
  end

  def test_clear_data_without_format_clears_all
    dt = Dommy::DataTransfer.new
    dt.set_data("text/plain", "a")
    dt.set_data("text/html", "b")
    dt.clear_data
    assert_empty(dt.types)
  end

  # --- JS bridge ---------------------------------------------------

  def test_data_transfer_js_get_files
    file = Dommy::File.new(["x"], "a")
    dt = Dommy::DataTransfer.new(files: [file])
    assert_kind_of(Dommy::FileList, dt.__js_get__("files"))
  end

  def test_data_transfer_js_get_drop_effect_default
    dt = Dommy::DataTransfer.new
    assert_equal("none", dt.__js_get__("dropEffect"))
  end

  def test_data_transfer_js_set_drop_effect
    dt = Dommy::DataTransfer.new
    dt.__js_set__("dropEffect", "copy")
    assert_equal("copy", dt.__js_get__("dropEffect"))
  end

  def test_data_transfer_js_call_get_set_clear
    dt = Dommy::DataTransfer.new
    dt.__js_call__("setData", ["text/plain", "hello"])
    assert_equal("hello", dt.__js_call__("getData", ["text/plain"]))
    dt.__js_call__("clearData", ["text/plain"])
    assert_equal("", dt.__js_call__("getData", ["text/plain"]))
  end

  # --- DragEvent ---------------------------------------------------

  def test_drag_event_extends_mouse_event
    dt = Dommy::DataTransfer.new
    ev = Dommy::DragEvent.new("dragstart", "dataTransfer" => dt)
    assert_kind_of(Dommy::MouseEvent, ev)
    assert_kind_of(Dommy::Event, ev)
  end

  def test_drag_event_exposes_data_transfer
    dt = Dommy::DataTransfer.new
    ev = Dommy::DragEvent.new("drop", "dataTransfer" => dt)
    assert_same(dt, ev.data_transfer)
    assert_same(dt, ev.__js_get__("dataTransfer"))
  end

  def test_drag_event_inherits_mouse_coords
    ev = Dommy::DragEvent.new("drop", "clientX" => 100, "clientY" => 200)
    assert_equal(100, ev.__js_get__("clientX"))
    assert_equal(200, ev.__js_get__("clientY"))
  end

  # --- End-to-end: drop event delivers files ----------------------

  def test_drop_event_delivers_files_via_data_transfer
    win = make_window("<div id='dropzone'></div>")
    dropzone = win.document.query_selector("#dropzone")

    received_files = nil
    dropzone.add_event_listener(
      "drop",
      proc { |e|
        received_files = e.__js_get__("dataTransfer").files
      }
    )

    file = Dommy::File.new(["pdf"], "doc.pdf", "type" => "application/pdf")
    dt = Dommy::DataTransfer.new(files: [file])
    ev = Dommy::DragEvent.new("drop", "dataTransfer" => dt, "bubbles" => true)
    dropzone.dispatch_event(ev)

    refute_nil(received_files)
    assert_equal(1, received_files.length)
    assert_equal("doc.pdf", received_files[0].name)
  end

  # --- Window bridge ----------------------------------------------

  def test_window_exposes_data_transfer_constructor
    win = make_window
    ctor = win.__js_get__("DataTransfer")
    dt = ctor.__js_new__([{"files" => [Dommy::File.new(["x"], "a")]}])
    assert_kind_of(Dommy::DataTransfer, dt)
    assert_equal(1, dt.files.length)
  end

  def test_window_exposes_drag_event_constructor
    win = make_window
    ctor = win.__js_get__("DragEvent")
    dt = Dommy::DataTransfer.new
    ev = ctor.__js_new__(["dragenter", {"dataTransfer" => dt}])
    assert_kind_of(Dommy::DragEvent, ev)
    assert_same(dt, ev.data_transfer)
  end
end
