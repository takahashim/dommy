# frozen_string_literal: true

require_relative "test_helper"

# Verify the live behavior of getElementsByTagName / ClassName / Name
# (in line with the WHATWG spec — these must return live HTMLCollection
# instances, not snapshots).
class TestLiveTagNameCollection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div><p>1</p><p>2</p></div>")
    @doc = @win.document
  end

  def test_returns_HTMLCollection
    assert_kind_of(Dommy::HTMLCollection, @doc.get_elements_by_tag_name("p"))
  end

  def test_reflects_appended_match
    list = @doc.get_elements_by_tag_name("p")
    before = list.length
    @doc.body.append(@doc.create_element("p"))
    assert_equal(before + 1, list.length)
  end

  def test_reflects_removed_match
    list = @doc.get_elements_by_tag_name("p")
    before = list.length
    @doc.query_selector("p").remove
    assert_equal(before - 1, list.length)
  end

  def test_star_selector_matches_all_elements
    list = @doc.get_elements_by_tag_name("*")
    assert_operator(list.length, :>, 2)
  end

  def test_element_local_get_elements_by_tag_name_is_live
    div = @doc.query_selector("div")
    list = div.get_elements_by_tag_name("p")
    assert_kind_of(Dommy::HTMLCollection, list)
    before = list.length
    div.append(@doc.create_element("p"))
    assert_equal(before + 1, list.length)
  end
end

class TestLiveClassNameCollection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div class='a'></div><div class='a'></div>")
    @doc = @win.document
  end

  def test_returns_HTMLCollection
    assert_kind_of(Dommy::HTMLCollection, @doc.get_elements_by_class_name("a"))
  end

  def test_reflects_added_match
    list = @doc.get_elements_by_class_name("a")
    before = list.length
    el = @doc.create_element("span")
    el.set_attribute("class", "a")
    @doc.body.append(el)
    assert_equal(before + 1, list.length)
  end

  def test_empty_token_list_returns_empty
    list = @doc.get_elements_by_class_name("")
    assert_equal(0, list.length)
    assert(list.empty?)
  end

  def test_multiple_tokens_require_all
    @doc.body.inner_html = "<div class='a b'></div><div class='a'></div>"
    assert_equal(1, @doc.get_elements_by_class_name("a b").length)
    assert_equal(2, @doc.get_elements_by_class_name("a").length)
  end
end

class TestLiveByName < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<input name='x'><input name='x'>")
    @doc = @win.document
  end

  def test_returns_HTMLCollection
    assert_kind_of(Dommy::HTMLCollection, @doc.get_elements_by_name("x"))
  end

  def test_reflects_added_match
    list = @doc.get_elements_by_name("x")
    before = list.length
    new_el = @doc.create_element("input")
    new_el.set_attribute("name", "x")
    @doc.body.append(new_el)
    assert_equal(before + 1, list.length)
  end
end
