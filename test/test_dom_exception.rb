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

  def test_attach_shadow_invalid_mode_raises_syntax_error
    host = @doc.get_element_by_id("h")
    assert_raises(Dommy::DOMException::SyntaxError) do
      host.attach_shadow({"mode" => "foo"})
    end
  end

  def test_attach_shadow_twice_raises_invalid_state
    host = @doc.get_element_by_id("h")
    host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::InvalidStateError) { host.attach_shadow({"mode" => "open"}) }
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

  def test_dispatch_event_with_non_event_raises_type_error
    # TypeError stays as TypeError per spec (not a DOMException).
    el = @doc.get_element_by_id("h")
    assert_raises(TypeError) { el.dispatch_event("not-an-event") }
  end

  def test_rescue_dom_exception_catches_all_named
    raised = nil
    begin
      @doc.get_element_by_id("h").attach_shadow({"mode" => "bogus"})
    rescue Dommy::DOMException => e
      raised = e
    end

    refute_nil(raised)
    assert_equal("SyntaxError", raised.name)
    assert_equal(12, raised.code)
  end
end
