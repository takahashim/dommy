# frozen_string_literal: true

require_relative "../test_helper"

# WPT-flavoured coverage for conditional/grouping at-rules feeding the cascade:
# @media nesting, @layer (real cascade-layer ordering — layered styles sort
# between origin and specificity), and @import splicing. Adapted (not mirrored):
# WPT uses testharness.js / reftests; here rules are applied through
# getComputedStyle.
#
# WPT: css/css-cascade/layer-*.html, css/css-cascade/import-*.html,
#      css/mediaqueries/*.html
# Spec: https://drafts.csswg.org/css-cascade-5/#layering,
#       https://drafts.csswg.org/css-cascade-5/#at-import,
#       https://drafts.csswg.org/mediaqueries-4/
class TestWPTCssCascadeAtRules < Minitest::Test
  def computed(html, id, resolver: nil)
    document = Dommy.parse(html).document
    document.css_import_resolver = resolver if resolver
    document.default_view.get_computed_style(document.get_element_by_id(id))
  end

  # mediaqueries-4: a matching @media applies its block; nested @media is an
  # AND of the conditions.
  def test_media_query_match_and_nesting
    cs = computed(<<~HTML, "t")
      <style>
        @media (min-width: 100px) { #t { color: red } }
        @media screen { @media (min-width: 5000px) { #t { color: blue } } }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", cs["color"]
  end

  # css-cascade-5 §6.4.2: unlayered styles act as a final implicit layer, so an
  # unlayered rule beats a layered one even at lower specificity — here equal.
  def test_unlayered_beats_layered
    cs = computed(<<~HTML, "t")
      <style>
        @layer base { #t { color: red } }
        #t { color: green }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  def test_layer_block_rules_participate
    cs = computed('<style>@layer a { .c { color: red } }</style><p id="t" class="c">x</p>', "t")
    assert_equal "rgb(255, 0, 0)", cs["color"]
  end

  # css-cascade-5 §6.4.2: for normal declarations a later layer wins; layer
  # order is set by first declaration (the `@layer a, b;` statement here).
  def test_later_layer_wins_for_normal
    cs = computed(<<~HTML, "t")
      <style>
        @layer a, b;
        @layer b { #t { color: green } }
        @layer a { #t { color: red } }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # Layer order beats specificity: a low-specificity rule in a later layer wins
  # over a high-specificity rule in an earlier layer.
  def test_layer_order_outranks_specificity
    cs = computed(<<~HTML, "t")
      <style>
        @layer a, b;
        @layer a { p#t.c { color: red } }
        @layer b { p { color: green } }
      </style>
      <p id="t" class="c">x</p>
    HTML
    assert_equal "rgb(0, 128, 0)", cs["color"]
  end

  # For important declarations the layer order reverses — an earlier layer wins.
  def test_important_reverses_layer_order
    cs = computed(<<~HTML, "t")
      <style>
        @layer a, b;
        @layer a { #t { color: red !important } }
        @layer b { #t { color: green !important } }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", cs["color"]
  end

  # A sublayer is ordered after its parent (`@layer outer.inner` declares
  # `outer` first), so for normal rules the sublayer wins.
  def test_nested_sublayer_after_parent
    cs = computed(<<~HTML, "t")
      <style>
        @layer outer.inner { #t { color: red } }
        @layer outer { #t { color: green } }
      </style>
      <p id="t">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", cs["color"]
  end

  # css-cascade-5 §3.1: @import brings the referenced sheet's rules in at its
  # position (so a later same-specificity rule in the host sheet wins on order).
  def test_import_splices_at_position
    cs = computed(
      '<style>@import url(base.css); #t { color: green }</style><p id="t">x</p>',
      "t",
      resolver: ->(url) { url == "base.css" ? "#t { color: red; font-weight: bold }" : nil }
    )
    assert_equal "rgb(0, 128, 0)", cs["color"]
    assert_equal "700", cs["font-weight"]
  end

  def test_import_is_recursive_and_media_gated
    sheets = {
      "a.css" => "@import url(b.css); @import \"big.css\" (min-width: 9999px);",
      "b.css" => "#t { color: red }",
      "big.css" => "#t { color: blue }"
    }
    cs = computed(
      '<style>@import url(a.css);</style><p id="t">x</p>',
      "t",
      resolver: ->(url) { sheets[url] }
    )
    assert_equal "rgb(255, 0, 0)", cs["color"] # b.css applied; big.css media-gated out
  end
end
