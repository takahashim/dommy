# frozen_string_literal: true

require_relative "test_helper"

# HTML "constructing the entry list", XHR's `new FormData(form, submitter)`,
# `requestSubmit()`'s argument checks and the dialog submission method.
class TestFormSubmissionSpec < Minitest::Test
  include DommyTestHelper

  def setup_page(html)
    @win = make_window(html)
    @doc = @win.document
  end

  def entries(form, submitter = nil)
    Dommy::FormData.new(form, submitter).entries
  end

  def test_entry_list_searches_the_forms_own_tree
    setup_page("<div id=host></div>")
    form = @doc.create_element("form")
    form.id = "f"
    wrapper = @doc.create_element("div")
    wrapper.inner_html = "<input name=a value=1><datalist><input name=b value=2></datalist>"
    wrapper.append_child(form)
    form.inner_html = "<input name=c value=3>"
    # A detached tree: the form is not in the document.
    assert_equal [%w[c 3]], entries(form)
    attached = wrapper.query_selector("input[name=a]")
    attached.set_attribute("form", "f")
    # `form=` only applies while connected; the datalist input never counts.
    @doc.body.append_child(wrapper)
    assert_equal [%w[a 1], %w[c 3]], entries(form)
  end

  def test_submitter_entry_is_in_tree_order
    setup_page(<<~HTML)
      <form id=f><input name=n1 value=v1><button name=named value=b>x</button><input name=n3 value=v3>
      <input type=image name=img></form>
    HTML
    form = @doc.get_element_by_id("f")
    button = @doc.query_selector("button")
    assert_equal [%w[n1 v1], %w[named b], %w[n3 v3]], entries(form, button)
    image = @doc.query_selector("input[type=image]")
    assert_equal [%w[n1 v1], %w[n3 v3], %w[img.x 0], %w[img.y 0]], entries(form, image)
  end

  def test_formdata_submitter_checks
    setup_page("<form id=f><input name=n1><button id=b>x</button></form><button id=out>y</button>")
    form = @doc.get_element_by_id("f")
    assert_raises(Dommy::Bridge::TypeError) { Dommy::FormData.new(form, @doc.query_selector("[name=n1]")) }
    assert_raises(Dommy::DOMException::NotFoundError) { Dommy::FormData.new(form, @doc.get_element_by_id("out")) }
  end

  def test_reentrant_construction_is_an_invalid_state_error
    setup_page("<form id=f><input name=a value=1></form>")
    form = @doc.get_element_by_id("f")
    error = nil
    form.add_event_listener("formdata", proc {
      begin
        Dommy::FormData.new(form)
      rescue Dommy::DOMException::InvalidStateError => e
        error = e
      end
    })
    Dommy::FormData.new(form)
    refute_nil error
  end

  def test_dirname_only_follows_a_submitted_entry
    setup_page("<form id=f><input dirname=d value=x><input name=n dirname=d2 value=y></form>")
    assert_equal [%w[n y], %w[d2 ltr]], entries(@doc.get_element_by_id("f"))
  end

  def test_charset_hidden_input_reports_the_encoding_even_with_a_value
    setup_page("<form id=f><input type=hidden name=_charset_ value=x></form>")
    assert_equal [%w[_charset_ UTF-8]], entries(@doc.get_element_by_id("f"))
  end

  def test_request_submit_checks_the_form_owner
    setup_page("<form id=f></form><form id=g><button id=b form=f>x</button></form>")
    form = @doc.get_element_by_id("f")
    other = @doc.get_element_by_id("g")
    button = @doc.get_element_by_id("b")
    fired = nil
    form.add_event_listener("submit", proc { |e| fired = e; e.prevent_default })
    form.request_submit(button)
    assert_same button, fired.__js_get__("submitter")
    assert fired.__js_get__("isTrusted")
    assert_raises(Dommy::DOMException::NotFoundError) { other.request_submit(button) }
  end

  def test_dialog_method_closes_the_dialog_with_the_submitter_value
    setup_page(<<~HTML)
      <dialog id=d open><form method=dialog><button id=b value=yes>ok</button><input type=image id=i></form></dialog>
    HTML
    dialog = @doc.get_element_by_id("d")
    navigations = []
    @win.define_singleton_method(:__internal_navigate__) { |**kw| navigations << kw }
    @doc.get_element_by_id("b").click
    refute dialog.open
    assert_equal "yes", dialog.return_value
    assert_empty navigations

    dialog.show
    @doc.get_element_by_id("i").click
    assert_equal "0,0", dialog.return_value
  end

  def test_formmethod_dialog_overrides_the_form_method
    setup_page("<dialog id=d open><form method=post><button id=b formmethod=dialog>ok</button></form></dialog>")
    dialog = @doc.get_element_by_id("d")
    @doc.get_element_by_id("b").click
    refute dialog.open
    assert_equal "", dialog.return_value
  end
end
