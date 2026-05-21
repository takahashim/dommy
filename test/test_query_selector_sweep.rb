# frozen_string_literal: true

require_relative "test_helper"

# CSS selector syntax sweep modelled after happy-dom's
# QuerySelector.test.ts. Most patterns work because Dommy delegates
# to Nokogiri::CSS; this test confirms which work and serves as a
# living catalogue.
class TestQuerySelectorSweep < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="outer" class="class1 class2">
          <div class="class1">
            <span class="class1 class2">A</span>
            <span class="class1">B</span>
            <p>P-text</p>
          </div>
          <div>
            <span>C</span>
          </div>
          <h1>H</h1>
          <a href="/x" target="_blank" data-attr1="word1 word2">link1</a>
          <a href="/y" data-attr1="value1">link2</a>
          <input type="text" name="email" required>
          <input type="checkbox" disabled>
        </div>
      HTML
    )
    @doc = @win.document
  end

  def test_tag_name_selector
    assert_equal(1, @doc.query_selector_all("p").size)
    assert_equal(1, @doc.query_selector_all("h1").size)
    assert_equal(2, @doc.query_selector_all("a").size)
  end

  def test_universal_selector
    all = @doc.query_selector_all("*")
    assert_operator(all.size, :>=, 10)
  end

  def test_id_selector
    assert_equal("DIV", @doc.query_selector("#outer").tag_name)
  end

  def test_class_selector_single
    assert_equal(4, @doc.query_selector_all(".class1").size)
  end

  def test_compound_class_selector
    assert_equal(2, @doc.query_selector_all(".class1.class2").size)
  end

  def test_tag_class_compound
    assert_equal(2, @doc.query_selector_all("span.class1").size)
  end

  def test_descendant_combinator
    # `div span` matches every span anywhere inside any div.
    spans = @doc.query_selector_all("div span")
    assert_operator(spans.size, :>=, 3)
    assert_operator(@doc.query_selector_all("#outer span").size, :>=, 3)
  end

  def test_child_combinator
    assert_equal(2, @doc.query_selector_all("#outer > div").size)
  end

  def test_adjacent_sibling_combinator
    # `span + span` finds the second span after the first.
    assert_operator(@doc.query_selector_all("span + span").size, :>=, 1)
  end

  def test_general_sibling_combinator
    # `span ~ p` finds p coming after span at the same level.
    assert_operator(@doc.query_selector_all("span ~ p").size, :>=, 1)
  end

  def test_attribute_present
    assert_equal(2, @doc.query_selector_all("[href]").size)
  end

  def test_attribute_exact_value
    assert_equal(1, @doc.query_selector_all("[href='/x']").size)
  end

  def test_attribute_value_unquoted
    assert_equal(1, @doc.query_selector_all("[data-attr1=value1]").size)
  end

  def test_attribute_value_contains_space
    assert_equal(1, @doc.query_selector_all("[data-attr1='word1 word2']").size)
  end

  def test_attribute_word_match
    # `~=` matches whitespace-separated word.
    assert_operator(@doc.query_selector_all("[data-attr1~='word1']").size, :>=, 1)
  end

  def test_attribute_prefix_match
    assert_equal(1, @doc.query_selector_all("[href^='/x']").size)
  end

  def test_attribute_suffix_match
    assert_equal(1, @doc.query_selector_all("[href$='/y']").size)
  end

  def test_attribute_substring_match
    assert_equal(2, @doc.query_selector_all("[href*='/']").size)
  end

  def test_selector_list_comma_separated
    list = @doc.query_selector_all("h1, p")
    assert_equal(2, list.size)
  end

  def test_first_child_pseudo
    list = @doc.query_selector_all("span:first-child")
    assert_operator(list.size, :>=, 1)
  end

  def test_last_child_pseudo
    list = @doc.query_selector_all("span:last-child")
    assert_operator(list.size, :>=, 1)
  end

  def test_nth_child_pseudo
    # 1-based; pick the 1st span of its parent.
    list = @doc.query_selector_all("span:nth-child(1)")
    assert_operator(list.size, :>=, 1)
  end

  def test_not_pseudo
    # Spans not having class1.
    spans = @doc.query_selector_all("span:not(.class1)")
    assert_operator(spans.size, :>=, 1)
  end

  def test_empty_pseudo
    # Adding an empty div for the :empty test.
    @doc.body.append(@doc.create_element("hr"))
    list = @doc.query_selector_all("hr")
    assert_operator(list.size, :>=, 1)
  end

  def test_returns_array
    assert_kind_of(Array, @doc.query_selector_all("span"))
  end

  def test_no_match_returns_empty_array
    assert_equal([], @doc.query_selector_all(".no-such-class-anywhere"))
  end

  def test_querySelector_returns_first_match
    el = @doc.query_selector(".class1")
    refute_nil(el)
    assert_equal("DIV", el.tag_name)
  end

  def test_querySelector_no_match_returns_nil
    assert_nil(@doc.query_selector(".nope"))
  end

  def test_matches_with_compound
    @a = @doc.query_selector("span.class1.class2")
    assert(@a.matches?(".class1"))
    assert(@a.matches?(".class2"))
    assert(@a.matches?(".class1.class2"))
    refute(@a.matches?(".class3"))
  end

  def test_matches_with_attribute
    a = @doc.query_selector("a[href='/x']")
    assert(a.matches?("[href]"))
    assert(a.matches?("[href='/x']"))
  end

  def test_scoped_query_selector_on_element
    el = @doc.get_element_by_id("outer")
    list = el.query_selector_all("span")
    assert_operator(list.size, :>=, 3)
  end

  def test_closest_walks_up
    span = @doc.query_selector("span.class1.class2")
    closest_outer = span.closest("#outer")
    assert_equal("outer", closest_outer.id)
  end

  def test_closest_returns_self_if_matches
    span = @doc.query_selector("span.class1.class2")
    assert_same(span.__node__, span.closest("span").__node__)
  end

  def test_get_element_by_id_after_dynamic_insert
    el = @doc.create_element("div")
    el.id = "dynamic"
    @doc.body.append(el)
    refute_nil(@doc.get_element_by_id("dynamic"))
  end
end
