# frozen_string_literal: true

require_relative "test_helper"

class TestBlob < Minitest::Test
  include DommyTestHelper

  # --- Blob construction --------------------------------------------

  def test_empty_blob
    blob = Dommy::Blob.new
    assert_equal(0, blob.size)
    assert_equal("", blob.type)
  end

  def test_blob_from_string
    blob = Dommy::Blob.new(["Hello"], "type" => "text/plain")
    assert_equal(5, blob.size)
    assert_equal("text/plain", blob.type)
    assert_equal("Hello", blob.text)
  end

  def test_blob_from_multiple_parts
    blob = Dommy::Blob.new(["Hello", ", ", "world"])
    assert_equal(12, blob.size)
    assert_equal("Hello, world", blob.text)
  end

  def test_blob_from_array_of_bytes
    blob = Dommy::Blob.new([[72, 105]])
    assert_equal(2, blob.size)
    assert_equal("Hi", blob.text)
  end

  def test_blob_from_other_blob
    inner = Dommy::Blob.new(["Hello"])
    outer = Dommy::Blob.new([inner, " world"])
    assert_equal("Hello world", outer.text)
  end

  def test_blob_type_is_lowercased
    blob = Dommy::Blob.new(["x"], "type" => "TEXT/Plain")
    assert_equal("text/plain", blob.type)
  end

  def test_blob_accepts_symbol_options
    blob = Dommy::Blob.new(["x"], type: "text/html")
    assert_equal("text/html", blob.type)
  end

  # --- Blob slicing -------------------------------------------------

  def test_slice_returns_new_blob_with_range
    blob = Dommy::Blob.new(["Hello, world"])
    sliced = blob.slice(7, 12)
    assert_kind_of(Dommy::Blob, sliced)
    assert_equal("world", sliced.text)
  end

  def test_slice_with_negative_start
    blob = Dommy::Blob.new(["Hello, world"])
    assert_equal("world", blob.slice(-5).text)
  end

  def test_slice_with_content_type
    blob = Dommy::Blob.new(["abc"], "type" => "text/plain")
    sliced = blob.slice(0, 2, "text/html")
    assert_equal("text/html", sliced.type)
  end

  def test_array_buffer_returns_bytes
    blob = Dommy::Blob.new(["Hi"])
    # Blob.arrayBuffer()'s result is an ArrayBuffer (crosses as a bare one).
    assert_kind_of(Dommy::Bridge::ArrayBuffer, blob.array_buffer)
    assert_equal([72, 105], blob.array_buffer)
  end

  # WHATWG: Blob.text()/arrayBuffer() return Promises. A window-bearing Blob
  # (the JS-constructed case) resolves them via the scheduler.
  def test_js_text_and_array_buffer_are_promises
    win = make_window
    blob = Dommy::Blob.new(["Hi"], {"type" => "text/plain"}, win)

    text_promise = blob.__js_call__("text", [])
    assert_kind_of(Dommy::PromiseValue, text_promise)
    assert_equal("Hi", text_promise.await)

    ab_promise = blob.__js_call__("arrayBuffer", [])
    assert_kind_of(Dommy::PromiseValue, ab_promise)
    assert_kind_of(Dommy::Bridge::ArrayBuffer, ab_promise.await)
  end

  def test_js_text_falls_back_to_value_without_window
    # A window-less Blob returns the value directly (await still copes).
    assert_equal("Hi", Dommy::Blob.new(["Hi"]).__js_call__("text", []))
  end

  def test_slice_preserves_window
    win = make_window
    blob = Dommy::Blob.new(["Hello"], {}, win)
    assert_kind_of(Dommy::PromiseValue, blob.slice(0, 2).__js_call__("text", []))
  end

  # --- File --------------------------------------------------------

  def test_file_inherits_blob
    file = Dommy::File.new(["content"], "data.txt", "type" => "text/plain")
    assert_kind_of(Dommy::Blob, file)
  end

  def test_file_has_name
    file = Dommy::File.new(["x"], "report.csv")
    assert_equal("report.csv", file.name)
  end

  def test_file_size_and_type
    file = Dommy::File.new(["Hello"], "a.txt", "type" => "text/plain")
    assert_equal(5, file.size)
    assert_equal("text/plain", file.type)
  end

  def test_file_last_modified_defaults_to_now_in_ms
    before = (Time.now.to_f * 1000).to_i
    file = Dommy::File.new(["x"], "a.txt")
    after = (Time.now.to_f * 1000).to_i
    assert_operator(file.last_modified, :>=, before)
    assert_operator(file.last_modified, :<=, after)
  end

  def test_file_accepts_last_modified
    file = Dommy::File.new(["x"], "a.txt", "lastModified" => 1234567890)
    assert_equal(1234567890, file.last_modified)
  end

  # --- FileList ----------------------------------------------------

  def test_file_list_length
    files = [Dommy::File.new(["a"], "a"), Dommy::File.new(["b"], "b")]
    list = Dommy::FileList.new(files)
    assert_equal(2, list.length)
    assert_equal(2, list.size)
  end

  def test_file_list_item_access
    files = [Dommy::File.new(["a"], "first"), Dommy::File.new(["b"], "second")]
    list = Dommy::FileList.new(files)
    assert_equal("first", list[0].name)
    assert_equal("second", list.item(1).name)
    assert_nil(list[5])
  end

  def test_file_list_is_enumerable
    files = [Dommy::File.new(["a"], "a"), Dommy::File.new(["b"], "b")]
    list = Dommy::FileList.new(files)
    names = list.map(&:name)
    assert_equal(%w[a b], names)
  end

  def test_empty_file_list
    list = Dommy::FileList.new
    assert_equal(0, list.length)
    assert(list.empty?)
  end

  # --- JS bridge ---------------------------------------------------

  def test_blob_js_get_size_and_type
    blob = Dommy::Blob.new(["abc"], "type" => "text/plain")
    assert_equal(3, blob.__js_get__("size"))
    assert_equal("text/plain", blob.__js_get__("type"))
  end

  def test_blob_js_call_slice
    blob = Dommy::Blob.new(["abcdef"])
    sliced = blob.__js_call__("slice", [1, 4])
    assert_equal("bcd", sliced.text)
  end

  def test_file_js_get_name_and_last_modified
    file = Dommy::File.new(["x"], "a.txt", "lastModified" => 1234)
    assert_equal("a.txt", file.__js_get__("name"))
    assert_equal(1234, file.__js_get__("lastModified"))
  end

  def test_file_list_js_get_length
    list = Dommy::FileList.new([Dommy::File.new(["a"], "a")])
    assert_equal(1, list.__js_get__("length"))
  end

  def test_file_list_js_get_by_index
    file = Dommy::File.new(["a"], "first")
    list = Dommy::FileList.new([file])
    assert_equal(file, list.__js_get__(0))
    assert_equal(file, list.__js_get__("0"))
  end

  # --- Window bridge ----------------------------------------------

  def test_window_exposes_blob_constructor
    win = make_window
    ctor = win.__js_get__("Blob")
    blob = ctor.__js_new__([["Hi"]])
    assert_equal("Hi", blob.text)
  end

  def test_window_exposes_file_constructor
    win = make_window
    ctor = win.__js_get__("File")
    file = ctor.__js_new__([["x"], "a.txt", {"type" => "text/plain"}])
    assert_equal("a.txt", file.name)
  end

  # --- HTMLInputElement integration --------------------------------

  def test_input_files_defaults_to_empty_file_list
    win = make_window("<input type='file' name='upload'>")
    input = win.document.query_selector("input")
    assert_kind_of(Dommy::FileList, input.files)
    assert_equal(0, input.files.length)
  end

  def test_input_set_files_seeds_file_list
    win = make_window("<input type='file' name='upload'>")
    input = win.document.query_selector("input")
    file = Dommy::File.new(["data"], "report.csv", "type" => "text/csv")
    input.__driver_set_files__([file])
    assert_equal(1, input.files.length)
    assert_equal("report.csv", input.files[0].name)
  end

  def test_input_files_via_js_get
    win = make_window("<input type='file' name='upload'>")
    input = win.document.query_selector("input")
    input.__driver_set_files__([Dommy::File.new(["x"], "a")])
    assert_kind_of(Dommy::FileList, input.__js_get__("files"))
  end

  # --- FormData integration ---------------------------------------

  def test_formdata_includes_file_input_files
    win = make_window(
      <<~HTML
        <form>
          <input type="text" name="title" value="Report">
          <input type="file" name="attachment">
        </form>
      HTML
    )
    form = win.document.query_selector("form")
    input = form.query_selector("input[type='file']")
    input.__driver_set_files__([Dommy::File.new(["pdf"], "doc.pdf", "type" => "application/pdf")])

    fd = Dommy::FormData.new(form)
    entries = fd.entries.to_a
    file_entry = entries.find { |name, _| name == "attachment" }
    refute_nil(file_entry)
    assert_kind_of(Dommy::File, file_entry[1])
    assert_equal("doc.pdf", file_entry[1].name)
  end

  def test_formdata_multiple_files_become_multiple_entries
    win = make_window("<form><input type='file' name='photos' multiple></form>")
    form = win.document.query_selector("form")
    input = form.query_selector("input")
    input.__driver_set_files__(
      [
        Dommy::File.new(["a"], "a.jpg"),
        Dommy::File.new(["b"], "b.jpg")
      ]
    )

    fd = Dommy::FormData.new(form)
    photo_entries = fd.entries.to_a.select { |name, _| name == "photos" }
    assert_equal(2, photo_entries.size)
    assert_equal(%w[a.jpg b.jpg], photo_entries.map { |_, v| v.name })
  end

  def test_formdata_append_blob_passes_through
    fd = Dommy::FormData.new
    blob = Dommy::Blob.new(["data"], "type" => "application/octet-stream")
    fd.append("payload", blob)
    pairs = fd.entries.to_a
    assert_equal(1, pairs.size)
    assert_equal("payload", pairs[0][0])
    assert_kind_of(Dommy::Blob, pairs[0][1])
  end
end
