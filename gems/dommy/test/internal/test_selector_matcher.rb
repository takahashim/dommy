# frozen_string_literal: true

require_relative "../test_helper"

# SelectorMatcher correctness regressions: combinator backtracking, :has
# anchoring, pseudo-element subjects, fragment-rooted queries, closest's
# fixed :scope, and the smaller pseudo-class semantics.
class TestSelectorMatcher < Minitest::Test
  def doc_for(html)
    Dommy.parse(html).document
  end

  # --- backtracking ------------------------------------------------------

  def test_descendant_combinator_backtracks_past_a_failing_candidate
    doc = doc_for(<<~HTML)
      <div class="a"><div class="b"><div class="x"><div class="b"><div class="c" id="t"></div></div></div></div></div>
    HTML
    # The nearest .b ancestor's parent is .x; the match must retry the
    # outer .b whose parent is .a.
    assert_equal ["t"], doc.query_selector_all(".a > .b .c").map { |el| el.get_attribute("id") }
  end

  def test_subsequent_sibling_combinator_backtracks
    doc = doc_for('<ul><li class="a">1</li><li class="b">2</li><li class="b">3</li><li class="c" id="t">4</li></ul>')
    assert_equal ["t"], doc.query_selector_all(".a + .b ~ .c").map { |el| el.get_attribute("id") }
  end

  # --- pseudo-element subjects -------------------------------------------

  def test_pseudo_element_subject_never_matches_an_element
    doc = doc_for('<div id="t"></div>')
    assert_empty doc.query_selector_all("div::before").to_a
    assert_empty doc.query_selector_all("::before").to_a
    refute doc.get_element_by_id("t").matches?("div::before")
  end

  # --- :has() anchoring ---------------------------------------------------

  def test_has_left_end_stays_inside_the_anchor
    doc = doc_for('<div class="a"><section><b class="b">x</b></section></div>')
    # .a lies outside the section, so the relative ".a .b" must not match.
    assert_empty doc.query_selector_all("section:has(.a .b)").to_a
    assert_equal 1, doc.query_selector_all("div:has(section .b)").length
  end

  def test_has_sibling_relative_subject_may_live_inside_the_sibling
    doc = doc_for('<label id="l">c</label><div><i class="deep" id="d"></i></div>')
    # The relative complex's subject (.deep) is a descendant of the
    # adjacent sibling, with the sibling relation anchored at the label.
    assert_equal ["l"], doc.query_selector_all("label:has(+ div .deep)").map { |el| el.get_attribute("id") }
  end

  # --- fragment / closest / column ---------------------------------------

  def test_query_selector_on_an_element_inside_a_fragment
    doc = doc_for("<p>x</p>")
    fragment = doc.create_document_fragment
    el = doc.create_element("div")
    el.inner_html = "<p id='inner'>z</p>"
    fragment.append_child(el)

    assert_equal 1, el.query_selector_all("p").length
    assert_equal "inner", el.query_selector("p").get_attribute("id")
  end

  def test_closest_keeps_the_original_element_as_scope
    doc = doc_for('<div><p id="p">x</p></div>')
    assert_nil doc.get_element_by_id("p").closest("div:scope")
    refute_nil doc.get_element_by_id("p").closest("div")
  end

  def test_column_combinator_matches_nothing
    doc = doc_for('<div id="q">x</div><p id="w">y</p>')
    assert_empty doc.query_selector_all("div || p").to_a
  end

  # --- :lang() / :dir() ----------------------------------------------------

  def test_lang_uses_extended_filtering_and_range_lists
    doc = doc_for('<div lang="de-Latn-DE" id="a"></div><div lang="en-US" id="b"></div>')
    assert doc.get_element_by_id("a").matches?(":lang(de-DE)")
    assert_equal ["b"], doc.query_selector_all("div:lang(en, fr)").map { |el| el.get_attribute("id") }
    refute doc.get_element_by_id("b").matches?(":lang(fr)")
  end

  def test_dir_matches_the_nearest_dir_attribute_with_ltr_default
    doc = doc_for('<div dir="rtl"><p id="p">x</p></div><p id="q">y</p>')
    assert doc.get_element_by_id("p").matches?(":dir(rtl)")
    refute doc.get_element_by_id("p").matches?(":dir(ltr)")
    assert doc.get_element_by_id("q").matches?(":dir(ltr)")
  end

  # --- namespace ------------------------------------------------------------

  def test_null_namespace_type_selector
    doc = doc_for('<div id="d">x</div>')
    # `*|div` matches regardless of namespace; a bare `div` (no @namespace
    # rules) too.
    assert_equal 1, doc.query_selector_all("*|div").length
    assert_equal 1, doc.query_selector_all("div").length
  end
end
