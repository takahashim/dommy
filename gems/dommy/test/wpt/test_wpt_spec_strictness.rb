# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the previously-divergent edge cases that
# Dommy now handles strictly per spec:
#   - DOMTokenList token validation
#   - attachShadow host type + required mode
#   - HTMLFormElement.submit() vs requestSubmit()
#   - Node.baseURI honors <base href>
#   - new DOMException(msg, name) recovers legacy code
class TestWPTClassListValidation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='a'></div>")
    @doc = @win.document
    @list = @doc.get_element_by_id("x").class_list
  end

  # WPT: dom/lists/DOMTokenList-coverage-for-attributes.html

  def test_add_empty_string_throws_SyntaxError
    assert_raises(Dommy::DOMException::SyntaxError) { @list.add("") }
  end

  def test_add_whitespace_token_throws_InvalidCharacterError
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @list.add("a b") }
  end

  def test_remove_empty_string_throws_SyntaxError
    assert_raises(Dommy::DOMException::SyntaxError) { @list.remove("") }
  end

  def test_remove_whitespace_token_throws_InvalidCharacterError
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @list.remove("a\tb") }
  end

  def test_toggle_empty_string_throws_SyntaxError
    assert_raises(Dommy::DOMException::SyntaxError) { @list.__js_call__("toggle", [""]) }
  end

  def test_toggle_whitespace_throws_InvalidCharacterError
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @list.__js_call__("toggle", ["a b"]) }
  end

  def test_replace_empty_string_throws_SyntaxError
    assert_raises(Dommy::DOMException::SyntaxError) { @list.replace("", "x") }
    assert_raises(Dommy::DOMException::SyntaxError) { @list.replace("a", "") }
  end

  def test_replace_whitespace_throws_InvalidCharacterError
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @list.replace("a b", "x") }
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @list.replace("a", "x y") }
  end

  def test_contains_empty_string_does_NOT_throw
    # Spec exception: `contains` skips token validation.
    refute(@list.contains?(""))
  end
end

class TestWPTAttachShadowStrict < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  # WPT: shadow-dom/Element-interface-attachShadow.html

  def test_no_argument_raises_TypeError
    assert_raises(Dommy::Bridge::TypeError) { @host.attach_shadow }
  end

  def test_empty_init_dict_raises_TypeError
    assert_raises(Dommy::Bridge::TypeError) { @host.attach_shadow({}) }
  end

  def test_nil_mode_in_init_raises_TypeError
    assert_raises(Dommy::Bridge::TypeError) { @host.attach_shadow({"mode" => nil}) }
  end

  def test_input_cannot_host_shadow
    inp = @doc.create_element("input")
    assert_raises(Dommy::DOMException::NotSupportedError) do
      inp.attach_shadow({"mode" => "open"})
    end
  end

  def test_button_cannot_host_shadow
    btn = @doc.create_element("button")
    assert_raises(Dommy::DOMException::NotSupportedError) do
      btn.attach_shadow({"mode" => "open"})
    end
  end

  def test_select_cannot_host_shadow
    sel = @doc.create_element("select")
    assert_raises(Dommy::DOMException::NotSupportedError) do
      sel.attach_shadow({"mode" => "open"})
    end
  end

  def test_textarea_cannot_host_shadow
    ta = @doc.create_element("textarea")
    assert_raises(Dommy::DOMException::NotSupportedError) do
      ta.attach_shadow({"mode" => "open"})
    end
  end

  def test_div_can_host_shadow
    sr = @doc.create_element("div").attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
  end

  def test_section_can_host_shadow
    sr = @doc.create_element("section").attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
  end

  def test_custom_element_name_can_host_shadow
    sr = @doc.create_element("my-card").attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
  end
end

class TestWPTFormSubmit < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form id='f'>
          <input name='q'>
          <button id='go' type='submit'>Go</button>
          <button id='no' type='button'>No</button>
        </form>
      HTML
    )
    @doc = @win.document
    @form = @doc.get_element_by_id("f")
  end

  # WPT: html/semantics/forms/the-form-element/form-submit-twice.html
  # (covering: submit() ≠ requestSubmit())

  def test_submit_does_not_fire_submit_event
    fired = false
    @form.add_event_listener("submit", proc { fired = true })
    @form.submit
    refute(fired)
  end

  def test_request_submit_fires_submit_event
    fired = false
    @form.add_event_listener("submit", proc { fired = true })
    @form.request_submit
    assert(fired)
  end

  def test_request_submit_with_valid_submitter_fires_event
    fired = false
    @form.add_event_listener("submit", proc { fired = true })
    @form.request_submit(@doc.get_element_by_id("go"))
    assert(fired)
  end

  def test_request_submit_rejects_non_submit_button
    assert_raises(TypeError) do
      @form.request_submit(@doc.get_element_by_id("no"))
    end
  end

  def test_request_submit_rejects_external_button
    btn = @doc.create_element("button")
    btn.type = "submit"
    assert_raises(Dommy::DOMException::NotFoundError) do
      @form.request_submit(btn)
    end
  end
end

class TestWPTBaseURI < Minitest::Test
  include DommyTestHelper

  # WPT: dom/nodes/Node-baseURI.html

  def test_base_href_absolute_overrides_document_url
    win = make_window("<base href='https://x.test/sub/'><p id='p'>x</p>")
    el = win.document.get_element_by_id("p")
    assert_equal("https://x.test/sub/", el.base_uri)
  end

  def test_base_href_relative_resolves_against_doc_url
    win = make_window("<base href='/sub/'><p id='p'>x</p>")
    el = win.document.get_element_by_id("p")
    assert_includes(el.base_uri, "/sub/")
  end

  def test_first_base_wins
    win = make_window(
      <<~HTML
        <base href='https://first.test/'>
        <base href='https://second.test/'>
        <p id='p'>x</p>
      HTML
    )
    el = win.document.get_element_by_id("p")
    assert_equal("https://first.test/", el.base_uri)
  end

  def test_base_without_href_attribute_ignored
    win = make_window("<base><p id='p'>x</p>")
    el = win.document.get_element_by_id("p")
    refute_empty(el.base_uri)
  end

  def test_no_base_falls_back_to_document_url
    win = make_window("<p id='p'>x</p>")
    el = win.document.get_element_by_id("p")
    assert_equal(win.document.url, el.base_uri)
  end

  def test_document_base_uri_matches_element_base_uri
    win = make_window("<base href='https://x.test/'><p id='p'>x</p>")
    assert_equal(win.document.base_uri, win.document.get_element_by_id("p").base_uri)
  end
end

class TestWPTDOMExceptionLegacyCode < Minitest::Test
  # WPT: dom/exceptions/DOMException-constructor.html

  def test_known_name_recovers_code_via_base_ctor
    e = Dommy::DOMException.new("oops", "NotFoundError")
    assert_equal(8, e.code)
  end

  def test_all_legacy_names_resolve_via_base_ctor
    Dommy::DOMException::LEGACY_CODES.each do |name, expected_code|
      e = Dommy::DOMException.new("x", name)
      assert_equal(expected_code, e.code, "#{name} should have code #{expected_code}")
    end
  end

  def test_subclass_ctor_with_different_name_keeps_subclass_code
    # Spec: when constructed via a named subclass, .code reflects
    # that subclass even if a different .name is supplied.
    e = Dommy::DOMException::SyntaxError.new("msg", "NotFoundError")
    assert_equal(12, e.code)
  end

  def test_unknown_name_via_base_ctor_yields_code_zero
    e = Dommy::DOMException.new("msg", "TotallyMadeUp")
    assert_equal(0, e.code)
  end
end
