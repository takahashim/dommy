# frozen_string_literal: true

require_relative "test_helper"

class TestDOMExceptionClassHierarchy < Minitest::Test
  def test_base_is_standard_error
    assert(Dommy::DOMException < StandardError)
  end

  def test_named_subclasses_have_canonical_name_and_code
    cases = {
      Dommy::DOMException::IndexSizeError => ["IndexSizeError", 1],
      Dommy::DOMException::HierarchyRequestError => ["HierarchyRequestError", 3],
      Dommy::DOMException::WrongDocumentError => ["WrongDocumentError", 4],
      Dommy::DOMException::InvalidCharacterError => ["InvalidCharacterError", 5],
      Dommy::DOMException::NotFoundError => ["NotFoundError", 8],
      Dommy::DOMException::NotSupportedError => ["NotSupportedError", 9],
      Dommy::DOMException::InUseAttributeError => ["InUseAttributeError", 10],
      Dommy::DOMException::InvalidStateError => ["InvalidStateError", 11],
      Dommy::DOMException::SyntaxError => ["SyntaxError", 12],
      Dommy::DOMException::QuotaExceededError => ["QuotaExceededError", 22],
      Dommy::DOMException::TimeoutError => ["TimeoutError", 23]
    }
    cases.each do |klass, (name, code)|
      instance = klass.new("msg")
      assert_equal(name, instance.name, "#{klass} name")
      assert_equal(code, instance.code, "#{klass} code")
    end
  end

  def test_subclasses_inherit_dom_exception
    [
      Dommy::DOMException::IndexSizeError,
      Dommy::DOMException::HierarchyRequestError,
      Dommy::DOMException::NotFoundError,
      Dommy::DOMException::SyntaxError
    ].each do |klass|
      assert(klass < Dommy::DOMException, klass.to_s)
    end
  end
end

class TestDOMExceptionThrowSites < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='h'></div><table id='t'></table>")
    @doc = @win.document
  end

  def test_attach_shadow_invalid_mode_raises_type_error
    host = @doc.get_element_by_id("h")
    # ShadowRootMode is a WebIDL enum → an invalid value throws TypeError
    # (Bridge::TypeError, which the host bridge rethrows as a JS TypeError).
    assert_raises(Dommy::Bridge::TypeError) do
      host.attach_shadow({"mode" => "foo"})
    end
  end

  def test_attach_shadow_twice_raises_not_supported
    host = @doc.get_element_by_id("h")
    host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::NotSupportedError) { host.attach_shadow({"mode" => "open"}) }
  end

  def test_custom_elements_invalid_name_raises_syntax
    assert_raises(Dommy::DOMException::SyntaxError) do
      @win.custom_elements.define("nodash", Dommy::HTMLElement)
    end
  end

  def test_custom_elements_duplicate_raises_not_supported
    @win.custom_elements.define("my-thing", Class.new(Dommy::HTMLElement))
    assert_raises(Dommy::DOMException::NotSupportedError) do
      @win.custom_elements.define("my-thing", Dommy::HTMLElement)
    end
  end

  def test_table_insert_row_negative_raises_index_size
    table = @doc.get_element_by_id("t")
    assert_raises(Dommy::DOMException::IndexSizeError) { table.insert_row(-5) }
  end

  def test_table_insert_row_too_large_raises_index_size
    table = @doc.get_element_by_id("t")
    # table has 0 rows; index > 0 should fail.
    assert_raises(Dommy::DOMException::IndexSizeError) { table.insert_row(5) }
  end

  def test_remove_child_for_non_child_raises_not_found
    parent = @doc.get_element_by_id("h")
    stray = @doc.create_element("span")
    assert_raises(Dommy::DOMException::NotFoundError) { parent.remove_child(stray) }
  end

  def test_insert_before_with_non_child_reference_raises_not_found
    parent = @doc.get_element_by_id("h")
    node = @doc.create_element("span")
    stray = @doc.create_element("b") # not a child of parent
    assert_raises(Dommy::DOMException::NotFoundError) { parent.insert_before(node, stray) }
  end

  def test_insert_doctype_into_element_raises_hierarchy_request
    parent = @doc.get_element_by_id("h")
    doctype = @doc.implementation.create_document_type("html", "", "")
    assert_raises(Dommy::DOMException::HierarchyRequestError) { parent.append_child(doctype) }
  end

  def test_append_non_insertable_node_raises_hierarchy_request
    parent = @doc.get_element_by_id("h")
    # A Document is a Node but not an insertable child type.
    other = @doc.implementation.create_html_document("t")
    assert_raises(Dommy::DOMException::HierarchyRequestError) { parent.append_child(other) }
  end

  def test_append_child_null_raises_type_error
    parent = @doc.get_element_by_id("h")
    # WebIDL: the argument is a non-nullable Node.
    assert_raises(Dommy::Bridge::TypeError) { parent.append_child(nil) }
  end

  def test_append_child_null_on_leaf_raises_type_error
    text = @doc.create_text_node("x")
    # Coercion precedes the leaf's HierarchyRequestError.
    assert_raises(Dommy::Bridge::TypeError) { text.__js_call__("appendChild", [nil]) }
  end

  def test_dispatch_event_with_non_event_raises_type_error
    # TypeError stays as TypeError per spec (not a DOMException).
    el = @doc.get_element_by_id("h")
    assert_raises(TypeError) { el.dispatch_event("not-an-event") }
  end

  def test_rescue_dom_exception_catches_all_named
    raised = nil
    begin
      # An invalid selector raises DOMException::SyntaxError (a named subclass).
      @doc.get_element_by_id("h").query_selector("div % p")
    rescue Dommy::DOMException => e
      raised = e
    end

    refute_nil(raised)
    assert_equal("SyntaxError", raised.name)
    assert_equal(12, raised.code)
  end
end
