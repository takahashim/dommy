# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Document/Element lookup methods.
class TestWPTDocumentQuery < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="root">
          <div id="alpha" class="x">A</div>
          <div id="beta" class="x y">B</div>
          <p class="y">C</p>
          <input name="username">
        </div>
      HTML
    )
    @doc = @win.document
  end

  # ---- Document.getElementById ----
  # WPT: dom/nodes/Document-getElementById.html

  def test_getElementById_returns_element
    el = @doc.get_element_by_id("alpha")
    refute_nil(el)
    assert_equal("alpha", el.id)
  end

  def test_getElementById_missing_returns_nil
    assert_nil(@doc.get_element_by_id("missing"))
  end

  def test_getElementById_empty_string_returns_nil
    assert_nil(@doc.get_element_by_id(""))
  end

  def test_getElementById_first_match_when_duplicate
    @doc.body.append(
      @doc.create_element("div").tap { |e|
        e.id = "alpha"
        e.text_content = "second"
      }
    )
    # WPT spec says: id lookup returns the first element in tree order.
    assert_equal("A", @doc.get_element_by_id("alpha").text_content)
  end

  # ---- Document.getElementsByClassName ----
  # WPT: dom/nodes/Document-getElementsByClassName.html

  def test_getElementsByClassName_single_token
    list = @doc.get_elements_by_class_name("x")
    assert_equal(2, list.length)
  end

  def test_getElementsByClassName_multi_token_intersection
    list = @doc.get_elements_by_class_name("x y")
    assert_equal(1, list.length)
    assert_equal("beta", list[0].id)
  end

  def test_getElementsByClassName_no_match
    list = @doc.get_elements_by_class_name("nope")
    assert_equal(0, list.length)
  end

  def test_getElementsByClassName_returns_live_collection
    list = @doc.get_elements_by_class_name("x")
    assert_kind_of(Dommy::HTMLCollection, list)
    before = list.length
    new_el = @doc.create_element("span")
    new_el.set_attribute("class", "x")
    @doc.body.append(new_el)
    assert_equal(before + 1, list.length)
  end

  # ---- Document.getElementsByTagName ----
  # WPT: dom/nodes/Document-Element-getElementsByTagName.js

  def test_getElementsByTagName_lowercase
    list = @doc.get_elements_by_tag_name("div")
    assert(list.length >= 3)
  end

  def test_getElementsByTagName_uppercase_case_insensitive
    a = @doc.get_elements_by_tag_name("DIV").length
    b = @doc.get_elements_by_tag_name("div").length
    assert_equal(a, b)
  end

  def test_getElementsByTagName_star_returns_all_elements
    star = @doc.get_elements_by_tag_name("*")
    assert(star.length >= @doc.get_elements_by_tag_name("div").length)
  end

  def test_getElementsByTagName_unknown_returns_empty
    assert_equal(0, @doc.get_elements_by_tag_name("nosuch").length)
  end

  # ---- Document.getElementsByName ----
  # (HTMLDocument-only, paired with name attribute)

  def test_getElementsByName_returns_match
    list = @doc.get_elements_by_name("username")
    assert_equal(1, list.length)
    assert_equal("INPUT", list[0].tag_name)
  end

  def test_getElementsByName_unknown_returns_empty
    assert_equal(0, @doc.get_elements_by_name("nosuch").length)
  end

  # ---- Element.getElementsByClassName / TagName ----

  def test_element_getElementsByClassName_scoped
    root = @doc.get_element_by_id("root")
    list = root.get_elements_by_class_name("y")
    assert_equal(2, list.length)
  end

  def test_element_getElementsByTagName_scoped
    root = @doc.get_element_by_id("root")
    divs = root.get_elements_by_tag_name("div")
    # Excludes root itself; includes 2 descendant divs (alpha, beta).
    assert_equal(2, divs.length)
  end
end
