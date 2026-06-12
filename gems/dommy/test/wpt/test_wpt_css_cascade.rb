# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for the CSS cascade, exercised through
# getComputedStyle (the resolved-value pipe WPT's testharness cascade
# tests use). Adapted rather than mirrored verbatim: much of
# css/css-cascade/ is reftests, which need rendering.
#
# WPT: css/css-cascade/ (important declarations, cascade order,
#      CSS-wide keywords incl. revert), css/css-style-attr/ (style
#      attribute precedence), css/cssom/getComputedStyle-*.
# Spec: https://drafts.csswg.org/css-cascade-4/,
#       https://drafts.csswg.org/cssom/#resolved-values
class TestWPTCssCascade < Minitest::Test
  def computed(html, id)
    document = Dommy.parse(html).document
    document.default_view.get_computed_style(document.get_element_by_id(id))
  end

  # css-cascade §6.4: declaration importance beats normal regardless of
  # specificity or order.
  def test_important_declarations_override_normal_declarations
    cs = computed(<<~HTML, "t")
      <style>
        p { color: green !important }
        #t.c { color: red }
      </style>
      <p id="t" class="c">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # css-style-attr §3.1: the style attribute outranks any selector's
  # specificity at the same importance level...
  def test_style_attribute_overrides_id_selector
    cs = computed('<style>#t { color: red }</style><p id="t" style="color: green">x</p>', "t")
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # ...and an important style attribute outranks an important rule.
  def test_important_style_attribute_overrides_important_rule
    cs = computed(<<~HTML, "t")
      <style>#t { color: red !important }</style>
      <p id="t" style="color: green !important">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # css-cascade §6.1: origin — author normal beats UA normal regardless of
  # the UA rule's higher specificity ([hidden] is (0,1,0)).
  def test_author_origin_beats_ua_origin
    cs = computed('<style>div { display: grid }</style><div id="t" hidden>x</div>', "t")
    assert_equal "grid", cs["display"]
  end

  # css-cascade §6.3: higher specificity wins; equal specificity falls back
  # to source order.
  def test_cascade_sorts_by_specificity_then_order
    cs = computed(<<~HTML, "t")
      <style>
        .a { color: red }
        p { color: blue }
        .b { color: green }
      </style>
      <p id="t" class="a b">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # css-cascade §7.3: inherit takes the parent's computed value, even on a
  # non-inherited property.
  def test_inherit_keyword_on_a_non_inherited_property
    cs = computed(<<~HTML, "t")
      <style>
        #outer { background-color: green }
        #t { background-color: inherit }
      </style>
      <div id="outer"><p id="t">x</p></div>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["background-color"]
  end

  # css-cascade §7.2: initial resets to the property's initial value.
  def test_initial_keyword
    cs = computed(<<~HTML, "t")
      <style>
        #outer { color: red }
        #t { color: initial }
      </style>
      <div id="outer"><p id="t">x</p></div>
    HTML
    assert_equal "rgb(0, 0, 0)", cs["color"]
  end

  # css-cascade §7.4: unset behaves as inherit for inherited properties and
  # as initial for non-inherited ones.
  def test_unset_keyword
    cs = computed(<<~HTML, "t")
      <style>
        #outer { color: green; background-color: red }
        #t { color: unset; background-color: unset }
      </style>
      <div id="outer"><p id="t">x</p></div>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
    assert_equal "rgba(0, 0, 0, 0)", cs["background-color"]
  end

  # css-cascade-4 §7.5 (revert): rolls back the author origin to the UA
  # default.
  def test_revert_keyword_rolls_back_to_ua
    cs = computed(<<~HTML, "t")
      <style>
        div { display: flex }
        #t { display: revert }
      </style>
      <div id="t">x</div>
    HTML
    assert_equal "block", cs["display"]
  end

  # cssom §resolved-values: colors serialize as rgb()/rgba().
  def test_resolved_color_serialization
    cs = computed('<style>#t { color: PapayaWhip; background-color: #8004 }</style><p id="t">x</p>', "t")
    assert_equal "rgb(255, 239, 213)", cs["color"]
    assert_equal "rgba(136, 0, 0, 0.26667)", cs["background-color"]
  end

  # css-cascade §7.3 (inheritance defaulting): inherited properties take the
  # parent's computed value through any depth.
  def test_inheritance_flows_through_intermediate_elements
    cs = computed(<<~HTML, "t")
      <style>#top { color: green }</style>
      <div id="top"><div><div><span id="t">x</span></div></div></div>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end
end
