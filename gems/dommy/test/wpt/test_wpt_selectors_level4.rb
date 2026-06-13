# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for Selectors Level 4 features exercised through
# querySelectorAll / matches: logical pseudo-classes (:is/:where/:not/:has),
# An+B with an `of S` clause, structural and state pseudo-classes, and :scope.
# Adapted (not mirrored): the WPT files are testharness.js pages over the same
# selectors; here they run against Dommy's AST matcher.
#
# WPT: css/selectors/is-where-*.html, css/selectors/has-*.html,
#      css/selectors/not-*.html, css/selectors/nth-child-of-*.html,
#      css/selectors/scope-*.html, dom/nodes/Element-matches.html
# Spec: https://drafts.csswg.org/selectors-4/
class TestWPTSelectorsLevel4 < Minitest::Test
  def doc(html)
    Dommy.parse(html).document
  end

  def ids(document, selector, root: nil)
    (root || document).query_selector_all(selector).map { |el| el.get_attribute("id") }
  end

  # selectors-4 §4.2: :is() matches if any selector in the list matches; its
  # specificity is the most specific argument.
  def test_is_matches_any_branch
    d = doc('<div id="a" class="x"></div><p id="b"></p><span id="c"></span>')
    assert_equal %w[a b], ids(d, ":is(.x, p)")
  end

  # :where() matches like :is() but contributes zero specificity.
  def test_where_specificity_is_zero
    d = doc('<style>:where(#a) { color: red } div { color: green }</style><div id="a">x</div>')
    view = d.default_view
    # div (0,0,1) beats :where(#id) (0,0,0) despite the id inside :where.
    assert_equal "rgb(0, 128, 0)", view.get_computed_style(d.get_element_by_id("a"))["color"]
  end

  # selectors-4 §4.3: :not() matches when none of its arguments match.
  def test_not_negates_a_selector_list
    d = doc('<p id="a" class="x"></p><p id="b"></p><p id="c" class="x y"></p>')
    assert_equal %w[b], ids(d, "p:not(.x)")
  end

  # selectors-4 §4.5: :has() matches an anchor with a relative match.
  def test_has_with_descendant_and_sibling
    d = doc(<<~HTML)
      <section id="s1"><p class="hit"></p></section>
      <section id="s2"><span></span></section>
      <h2 id="h1"></h2><p class="after"></p>
      <h2 id="h2"></h2><span></span>
    HTML
    assert_equal %w[s1], ids(d, "section:has(.hit)")
    assert_equal %w[h1], ids(d, "h2:has(+ .after)")
  end

  # selectors-4 §6.6.2: :nth-child(An+B of S) counts only siblings matching S.
  def test_nth_child_of_selector_list
    d = doc(<<~HTML)
      <ul>
        <li id="a" class="x"></li>
        <li id="b"></li>
        <li id="c" class="x"></li>
        <li id="d" class="x"></li>
      </ul>
    HTML
    # among .x children (a, c, d), the 2nd is c.
    assert_equal %w[c], ids(d, "li:nth-child(2 of .x)")
  end

  # selectors-4 §9: structural pseudo-classes ignore non-element nodes.
  def test_structural_pseudo_classes
    d = doc("<ul><li id=a>x</li>text<li id=b>y</li><li id=c>z</li></ul>")
    assert_equal %w[a], ids(d, "li:first-child")
    assert_equal %w[c], ids(d, "li:last-child")
    assert_equal %w[b], ids(d, "li:nth-child(2)")
    assert_equal %w[a c], ids(d, "li:nth-child(odd)")
  end

  # selectors-4 §10: form state pseudo-classes.
  def test_checked_disabled_enabled
    d = doc(<<~HTML)
      <input id="c1" type="checkbox" checked>
      <input id="c2" type="checkbox">
      <input id="d1" disabled>
      <button id="b1"></button>
    HTML
    assert_equal %w[c1], ids(d, ":checked")
    assert_equal %w[d1], ids(d, ":disabled")
    assert_includes ids(d, ":enabled"), "c1"
    assert_includes ids(d, ":enabled"), "b1"
    refute_includes ids(d, ":enabled"), "d1"
  end

  # An input nested in a disabled fieldset is :disabled (propagation); the
  # disabled fieldset itself is :disabled too.
  def test_fieldset_disabled_propagates
    d = doc('<fieldset id="f" disabled><input id="i"></fieldset>')
    assert_equal %w[f i], ids(d, ":disabled")
  end

  # dom §scope-match: :scope refers to the query context element; descendants
  # outside it are excluded, and left-hand compounds may match ancestors.
  def test_scope_in_element_query
    d = doc('<div id="root"><span class="x"><b id="t"></b></span></div><b id="o" class="y"></b>')
    root = d.get_element_by_id("root")
    assert_equal %w[t], ids(d, ":scope .x b", root: root)
  end

  # A state pseudo on a non-subject compound is evaluated at that position.
  def test_state_pseudo_on_non_subject_compound
    d = doc('<input id="i" type="checkbox" checked><label id="l">x</label><input type="checkbox"><label id="m">y</label>')
    assert_equal %w[l], ids(d, ":checked + label")
  end
end
