# frozen_string_literal: true

require_relative "test_helper"

class TestFormDataStandalone < Minitest::Test
  def test_empty_constructor
    fd = Dommy::FormData.new
    assert_equal(0, fd.size)
  end

  def test_append_pair
    fd = Dommy::FormData.new
    fd.append("name", "Alice")
    assert_equal("Alice", fd.get("name"))
  end

  def test_append_multiple_same_name
    fd = Dommy::FormData.new
    fd.append("tag", "ruby")
    fd.append("tag", "dom")
    assert_equal(["ruby", "dom"], fd.get_all("tag"))
  end

  def test_set_replaces_first_drops_rest
    fd = Dommy::FormData.new
    fd.append("k", "1")
    fd.append("k", "2")
    fd.set("k", "z")
    assert_equal(["z"], fd.get_all("k"))
  end

  def test_set_appends_if_missing
    fd = Dommy::FormData.new
    fd.set("a", "1")
    assert_equal("1", fd.get("a"))
  end

  def test_has
    fd = Dommy::FormData.new
    fd.append("a", "1")
    assert(fd.has("a"))
    refute(fd.has("b"))
  end

  def test_delete
    fd = Dommy::FormData.new
    fd.append("a", "1")
    fd.append("a", "2")
    fd.delete("a")
    refute(fd.has("a"))
  end

  def test_keys_values_entries
    fd = Dommy::FormData.new
    fd.append("a", "1")
    fd.append("b", "2")
    assert_equal(["a", "b"], fd.keys)
    assert_equal(["1", "2"], fd.values)
    assert_equal([["a", "1"], ["b", "2"]], fd.entries)
  end

  def test_for_each_yields_value_name_self
    fd = Dommy::FormData.new
    fd.append("a", "1")
    seen = []
    fd.for_each { |v, k, owner| seen << [k, v, owner.equal?(fd)] }
    assert_equal([["a", "1", true]], seen)
  end

  def test_nil_value_becomes_empty_string
    fd = Dommy::FormData.new
    fd.append("k", nil)
    assert_equal("", fd.get("k"))
  end
end

class TestFormDataFromForm < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form id='f'>
          <input name='username' value='alice'>
          <input name='email' value='a@b.test'>
          <input name='pw' value='secret' type='password'>
          <input name='ignored' type='submit' value='go'>
          <input name='unnamed_disabled' value='x' disabled>
          <input name='subscribe' type='checkbox' value='yes' checked>
          <input name='nochecked' type='checkbox' value='no'>
          <textarea name='bio'>hello</textarea>
          <select name='color'>
            <option value='red'>R</option>
            <option value='blue' selected>B</option>
          </select>
        </form>
      HTML
    )
    @doc = @win.document
    @form = @doc.get_element_by_id("f")
  end

  def test_collects_named_text_inputs
    fd = Dommy::FormData.new(@form)
    assert_equal("alice", fd.get("username"))
    assert_equal("a@b.test", fd.get("email"))
  end

  def test_collects_password_input
    fd = Dommy::FormData.new(@form)
    assert_equal("secret", fd.get("pw"))
  end

  def test_skips_submit_button
    fd = Dommy::FormData.new(@form)
    refute(fd.has("ignored"))
  end

  def test_skips_disabled
    fd = Dommy::FormData.new(@form)
    refute(fd.has("unnamed_disabled"))
  end

  def test_checkbox_checked_uses_value
    fd = Dommy::FormData.new(@form)
    assert_equal("yes", fd.get("subscribe"))
  end

  def test_checkbox_unchecked_omitted
    fd = Dommy::FormData.new(@form)
    refute(fd.has("nochecked"))
  end

  def test_textarea
    fd = Dommy::FormData.new(@form)
    assert_equal("hello", fd.get("bio"))
  end

  def test_select_selected_option
    fd = Dommy::FormData.new(@form)
    assert_equal("blue", fd.get("color"))
  end
end

class TestFormDataMultipart < Minitest::Test
  def test_text_only_multipart_structure
    fd = Dommy::FormData.new
    fd.append("title", "Hello")
    body, content_type = fd.__encode_multipart__("BOUND")

    assert_equal("multipart/form-data; boundary=BOUND", content_type)
    expected = +"--BOUND\r\n"
    expected << %(Content-Disposition: form-data; name="title"\r\n\r\n)
    expected << "Hello\r\n"
    expected << "--BOUND--\r\n"
    assert_equal(expected, body)
  end

  def test_file_part_includes_filename_and_content_type
    fd = Dommy::FormData.new
    fd.append("doc", Dommy::File.new(["hi"], "a.txt", "type" => "text/plain"))
    body, = fd.__encode_multipart__("BOUND")

    assert_includes(body, %(Content-Disposition: form-data; name="doc"; filename="a.txt"))
    assert_includes(body, "Content-Type: text/plain\r\n\r\nhi\r\n")
  end

  def test_file_without_type_defaults_to_octet_stream
    fd = Dommy::FormData.new
    fd.append("doc", Dommy::File.new(["x"], "f"))
    body, = fd.__encode_multipart__("BOUND")

    assert_includes(body, "Content-Type: application/octet-stream")
  end

  def test_content_type_has_generated_boundary
    body, content_type = Dommy::FormData.new.__encode_multipart__
    assert_match(%r{\Amultipart/form-data; boundary=----DommyFormBoundary[0-9a-f]+\z}, content_type)
    assert_equal(Encoding::ASCII_8BIT, body.encoding)
  end
end
