# frozen_string_literal: true

require_relative "test_helper"

class TestMutationObserverAttrs < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @records = []
    @obs = Dommy::MutationObserver.new(@win, proc { |recs| @records.concat(recs) })
  end

  def drain
    @win.scheduler.drain_microtasks
  end

  def test_attributes_option_records_setAttribute
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.set_attribute("data-x", "1")
    drain
    assert_equal(1, @records.size)
    assert_equal("attributes", @records.first.__js_get__("type"))
    assert_equal("data-x", @records.first.__js_get__("attributeName"))
  end

  def test_attribute_filter_skips_non_matching
    @obs.__js_call__("observe", [@root, {"attributes" => true, "attributeFilter" => ["only"]}])
    @root.set_attribute("only", "1")
    @root.set_attribute("ignored", "2")
    drain
    assert_equal(1, @records.size)
    assert_equal("only", @records.first.__js_get__("attributeName"))
  end

  # attributeFilter is a sequence<DOMString>: a value that is not a sequence
  # cannot convert, null and a string included.
  def test_attribute_filter_must_be_a_sequence
    [nil, "only", {}].each do |filter|
      assert_raises(Dommy::Bridge::TypeError) do
        @obs.__js_call__("observe", [@root, {"attributes" => true, "attributeFilter" => filter}])
      end
    end
  end

  # Each element goes through ToString: null is "null", 1.0 is "1".
  def test_attribute_filter_elements_convert_to_strings
    @obs.__js_call__("observe", [@root, {"attributeFilter" => [nil, 1.0]}])
    @root.set_attribute("null", "a")
    @root.set_attribute("1", "b")
    @root.set_attribute("other", "c")
    drain
    assert_equal(%w[null 1], @records.map { |r| r.__js_get__("attributeName") })
  end

  # The filter is matched against the attribute's local name as given: "ID"
  # is not "id".
  def test_attribute_filter_is_case_sensitive
    plain = @doc.create_element_ns(nil, "plain")
    @root.append_child(plain)
    @obs.__js_call__("observe", [@root, {"subtree" => true, "attributeFilter" => ["ID"]}])
    @root.set_attribute("id", "x")
    plain.set_attribute("ID", "y")
    drain
    assert_equal([plain], @records.map { |r| r.__js_get__("target") })
  end

  # An undefined member is as if missing: it implies nothing.
  def test_an_undefined_member_is_missing
    @obs.__js_call__("observe", [@root, {"childList" => true, "attributeOldValue" => Dommy::Bridge::UNDEFINED}])
    @root.set_attribute("data-x", "1")
    drain
    assert_empty(@records)
  end

  def test_attribute_old_value_supplied_when_requested
    @root.set_attribute("data-x", "first")
    @obs.__js_call__("observe", [@root, {"attributes" => true, "attributeOldValue" => true}])
    @root.set_attribute("data-x", "second")
    drain
    assert_equal("first", @records.first.__js_get__("oldValue"))
  end

  def test_attribute_old_value_nil_when_not_requested
    @root.set_attribute("data-x", "first")
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.set_attribute("data-x", "second")
    drain
    assert_nil(@records.first.__js_get__("oldValue"))
  end

  def test_class_name_setter_fires_attribute_record
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.class_name = "primary"
    drain
    assert_equal(1, @records.size)
    assert_equal("class", @records.first.__js_get__("attributeName"))
  end

  def test_class_list_add_fires_attribute_record
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.class_list.__js_call__("add", ["x"])
    drain
    assert_equal(1, @records.size)
    assert_equal("class", @records.first.__js_get__("attributeName"))
  end

  def test_dataset_set_fires_attribute_record
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.dataset.__js_set__("status", "ok")
    drain
    assert_equal("data-status", @records.first.__js_get__("attributeName"))
  end

  def test_style_setProperty_fires_attribute_record
    @obs.__js_call__("observe", [@root, {"attributes" => true}])
    @root.style.__js_call__("setProperty", ["color", "red"])
    drain
    assert_equal(1, @records.size)
    assert_equal("style", @records.first.__js_get__("attributeName"))
  end

  def test_subtree_attribute_observation
    child = @doc.create_element("span")
    @root.append_child(child)
    @obs.__js_call__("observe", [@root, {"attributes" => true, "subtree" => true}])
    child.set_attribute("data-y", "1")
    drain
    assert_equal(1, @records.size)
    assert_same(child, @records.first.__js_get__("target"))
  end

  def test_character_data_record
    p = @doc.create_element("p")
    text = @doc.create_text_node("first")
    p.append_child(text)
    @root.append_child(p)
    @obs.__js_call__("observe", [text, {"characterData" => true}])
    text.data = "second"
    drain
    assert_equal(1, @records.size)
    assert_equal("characterData", @records.first.__js_get__("type"))
  end

  def test_character_data_old_value
    text = @doc.create_text_node("first")
    @root.append_child(text)
    @obs.__js_call__("observe", [text, {"characterData" => true, "characterDataOldValue" => true}])
    text.data = "second"
    drain
    assert_equal("first", @records.first.__js_get__("oldValue"))
  end
end
