# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for DOMTokenList (Element.classList).
# WPT: dom/lists/DOMTokenList-*.html,
# dom/nodes/Element-classList.html
class TestWPTClassListBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='a b c'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
    @list = @el.class_list
  end

  # ---- length / item / iteration ----
  # WPT: Element-classList.html, DOMTokenList-stringifier.html

  def test_length_reflects_token_count
    assert_equal(3, @list.length)
  end

  def test_item_returns_token_at_index
    assert_equal("a", @list.item(0))
    assert_equal("b", @list.item(1))
    assert_equal("c", @list.item(2))
  end

  def test_item_out_of_range_returns_nil
    assert_nil(@list.item(99))
  end

  def test_bracket_access_returns_token
    assert_equal("a", @list[0])
    assert_equal("c", @list[2])
  end

  def test_iteration_in_document_order
    assert_equal(["a", "b", "c"], @list.to_a)
  end

  def test_each_yields_each_token
    seen = []
    @list.each { |t| seen << t }
    assert_equal(["a", "b", "c"], seen)
  end

  # ---- value getter / setter / stringifier ----
  # WPT: DOMTokenList-stringifier.html

  def test_value_getter_returns_full_class_string
    assert_equal("a b c", @list.value)
  end

  def test_value_setter_replaces_all_tokens
    @list.value = "x y"
    assert_equal("x y", @el.class_name)
    assert_equal(2, @list.length)
  end

  def test_to_s_returns_value
    assert_equal("a b c", @list.to_s)
  end

  # ---- contains ----
  # WPT: Element-classList.html

  def test_contains_true_for_present_token
    assert(@list.contains?("a"))
  end

  def test_contains_false_for_missing_token
    refute(@list.contains?("missing"))
  end

  def test_contains_case_sensitive
    refute(@list.contains?("A"))
  end

  def test_contains_empty_string_returns_false
    refute(@list.contains?(""))
  end
end

class TestWPTClassListMutations < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='a b'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
    @list = @el.class_list
  end

  # ---- add ----
  # WPT: Element-classList.html

  def test_add_appends_new_token
    @list.add("c")
    assert_equal("a b c", @el.class_name)
  end

  def test_add_existing_token_is_idempotent
    @list.add("a")
    assert_equal("a b", @el.class_name)
  end

  def test_add_multiple_tokens
    @list.add("c", "d")
    assert_equal("a b c d", @el.class_name)
  end

  def test_add_empty_attribute_creates_class
    @el.remove_attribute("class")
    @list.add("first")
    assert_equal("first", @el.class_name)
  end

  # ---- remove ----
  # WPT: Element-classList.html, DOMTokenList-coverage-for-attributes.html

  def test_remove_existing_token
    @list.remove("a")
    assert_equal("b", @el.class_name)
  end

  def test_remove_missing_token_is_noop
    @list.remove("z")
    assert_equal("a b", @el.class_name)
  end

  def test_remove_multiple_tokens
    @list.remove("a", "b")
    assert_equal("", @el.class_name)
  end

  def test_remove_last_token_empties_attribute
    # WHATWG: removing the last token runs the update steps, which serialize the
    # (now empty) token set back to the attribute — it stays present as "", it is
    # not removed (cf. Element-classlist.html: remove "a" from " a a a " => "").
    @el.set_attribute("class", "only")
    @el.class_list.remove("only")
    assert(@el.has_attribute?("class"))
    assert_equal("", @el.get_attribute("class"))
  end

  # ---- toggle ----
  # WPT: Element-classList.html

  def test_toggle_off_when_present_returns_false
    assert_equal(false, @list.__js_call__("toggle", ["a"]))
    refute(@list.contains?("a"))
  end

  def test_toggle_on_when_absent_returns_true
    assert_equal(true, @list.__js_call__("toggle", ["z"]))
    assert(@list.contains?("z"))
  end

  def test_toggle_force_true_keeps_token
    @list.__js_call__("toggle", ["a", true])
    assert(@list.contains?("a"))
  end

  def test_toggle_force_true_adds_missing_token
    result = @list.__js_call__("toggle", ["z", true])
    assert(result)
    assert(@list.contains?("z"))
  end

  def test_toggle_force_false_removes_token
    @list.__js_call__("toggle", ["a", false])
    refute(@list.contains?("a"))
  end

  def test_toggle_force_false_noop_when_absent
    result = @list.__js_call__("toggle", ["z", false])
    refute(result)
    refute(@list.contains?("z"))
  end

  # ---- replace ----
  # WPT: DOMTokenList-replace.html

  def test_replace_existing_token_returns_true
    assert_equal(true, @list.replace("a", "z"))
    assert_equal("z b", @el.class_name)
  end

  def test_replace_missing_token_returns_false
    assert_equal(false, @list.replace("missing", "x"))
    assert_equal("a b", @el.class_name)
  end

  def test_replace_preserves_position
    @el.set_attribute("class", "a b c")
    @el.class_list.replace("b", "z")
    assert_equal("a z c", @el.class_name)
  end

  def test_replace_with_already_present_dedupes
    @el.set_attribute("class", "a b")
    @el.class_list.replace("a", "b")
    # Both became "b" — uniq should leave a single "b".
    assert_equal("b", @el.class_name)
  end
end

class TestWPTClassListLive < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' class='a b'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
    @list = @el.class_list
  end

  # ---- live behavior ----
  # WPT: DOMTokenList-coverage-for-attributes.html

  def test_class_attribute_mutation_reflects_in_list
    @el.set_attribute("class", "fresh")
    assert_equal(1, @list.length)
    assert_equal("fresh", @list.item(0))
  end

  def test_list_mutation_reflects_in_class_attribute
    @list.add("new")
    assert_equal("a b new", @el.get_attribute("class"))
  end

  def test_classList_for_element_with_no_class_attr
    el = @doc.create_element("p")
    assert_equal(0, el.class_list.length)
    assert_equal("", el.class_list.value)
  end
end
