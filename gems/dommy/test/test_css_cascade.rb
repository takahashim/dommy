# frozen_string_literal: true

require_relative "test_helper"
require "dommy/internal/dom_matching"

# CSS cascade core (css-cascade.md P1): UA + author + inline + !important,
# inheritance, initial values, wide keywords, shorthand resets, and the
# generation-based cache invalidation. The parser comes from makiri/lexbor.
class TestCssCascade < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade

  def doc_for(html)
    Dommy.parse(html).document
  end

  def computed(doc, id)
    CASCADE.computed_style(doc.get_element_by_id(id))
  end

  # --- cascade order ------------------------------------------------

  def test_class_rule_applies_display_none
    doc = doc_for('<style>.hidden { display: none }</style><div class="hidden" id="x">x</div>')
    assert_equal "none", computed(doc, "x")["display"]
  end

  def test_specificity_orders_competing_rules
    doc = doc_for(<<~HTML)
      <style>
        #target { color: red }
        .c { color: blue }
        p { color: green }
      </style>
      <p id="target" class="c">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "target")["color"]
  end

  def test_equal_specificity_is_won_by_source_order
    doc = doc_for('<style>.a { color: red } .b { color: blue }</style><p class="a b" id="x">x</p>')
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_inline_style_beats_sheet_rules
    doc = doc_for('<style>#x { color: red }</style><p id="x" style="color: blue">x</p>')
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_important_rule_beats_inline_style
    doc = doc_for('<style>#x { color: red !important }</style><p id="x" style="color: blue">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_inline_important_beats_rule_important
    doc = doc_for(<<~HTML)
      <style>#x { color: red !important }</style>
      <p id="x" style="color: blue !important">x</p>
    HTML
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_author_rule_beats_ua_hidden_regardless_of_specificity
    # UA [hidden] is (0,1,0); the author type selector is (0,0,1) but wins
    # by origin — the documented [hidden]-vs-display-utility footgun.
    doc = doc_for('<style>div { display: flex }</style><div id="x" hidden>x</div>')
    assert_equal "flex", computed(doc, "x")["display"]
  end

  def test_ua_defaults_apply_without_author_css
    doc = doc_for('<div id="d"><span id="s">x</span></div>')
    assert_equal "block", computed(doc, "d")["display"]
    assert_equal "inline", computed(doc, "s")["display"]
  end

  # --- inheritance / initial ----------------------------------------

  def test_inherited_properties_flow_down_non_inherited_do_not
    doc = doc_for(<<~HTML)
      <style>#outer { color: green; display: flex; visibility: hidden }</style>
      <div id="outer"><p id="inner">x</p></div>
    HTML
    inner = computed(doc, "inner")
    assert_equal "rgb(0, 128, 0)", inner["color"]
    assert_equal "hidden", inner["visibility"]
    assert_equal "block", inner["display"] # UA <p>, not the parent's flex
  end

  def test_wide_keywords
    doc = doc_for(<<~HTML)
      <style>
        #outer { color: red }
        #a { color: inherit }
        #b { color: initial }
        #c { visibility: hidden }
        div { display: flex }
        #d { display: revert }
      </style>
      <div id="outer">
        <span id="a">a</span>
        <span id="b">b</span>
        <span id="c" style="visibility: unset">c</span>
      </div>
      <div id="d"></div>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "a")["color"]
    assert_equal "rgb(0, 0, 0)", computed(doc, "b")["color"]
    # unset on an inherited property = inherit; visibility:hidden matched on
    # #c itself is overridden by the inline unset -> inherits visible.
    assert_equal "visible", computed(doc, "c")["visibility"]
    # revert rolls the author/inline display back to the UA value for div.
    assert_equal "block", computed(doc, "d")["display"]
  end

  # --- computed-value transforms ------------------------------------

  def test_font_size_relative_units_resolve_against_the_parent
    doc = doc_for(<<~HTML)
      <style>
        #outer { font-size: 20px }
        #em { font-size: 1.5em }
        #pct { font-size: 50% }
        #rem { font-size: 2rem }
      </style>
      <div id="outer"><span id="em">x</span><span id="pct">x</span><span id="rem">x</span></div>
    HTML
    assert_equal "30px", computed(doc, "em")["font-size"]
    assert_equal "10px", computed(doc, "pct")["font-size"]
    assert_equal "32px", computed(doc, "rem")["font-size"]
  end

  def test_em_lengths_on_other_properties_resolve_against_own_font_size
    doc = doc_for('<style>#x { font-size: 10px; letter-spacing: 2em }</style><p id="x">x</p>')
    assert_equal "20px", computed(doc, "x")["letter-spacing"]
  end

  def test_absolute_length_units_resolve_to_px
    doc = doc_for('<style>#pt { font-size: 12pt } #in { text-indent: 1in }</style><p id="pt">x</p><p id="in">y</p>')
    assert_equal "16px", computed(doc, "pt")["font-size"]
    assert_equal "96px", computed(doc, "in")["text-indent"]
  end

  def test_viewport_units_resolve_against_the_viewport
    doc = doc_for('<style>#x { font-size: 10vw; letter-spacing: 1vh }</style><p id="x">x</p>')
    # default viewport is 1280x720
    assert_equal "128px", computed(doc, "x")["font-size"]
    assert_equal "7.2px", computed(doc, "x")["letter-spacing"]
  end

  def test_inherited_property_outside_color_font_inherits
    doc = doc_for('<style>#outer { text-transform: uppercase; text-indent: 5px }</style><div id="outer"><span id="inner">x</span></div>')
    assert_equal "uppercase", computed(doc, "inner")["text-transform"]
    assert_equal "5px", computed(doc, "inner")["text-indent"]
  end

  def test_current_color_resolves_to_the_elements_color
    doc = doc_for('<style>#x { color: red; background-color: currentColor }</style><p id="x">x</p>')
    styles = computed(doc, "x")
    assert_equal "rgb(255, 0, 0)", styles["color"]
    assert_equal "rgb(255, 0, 0)", styles["background-color"]
  end

  def test_current_color_resolves_per_element_not_to_the_ancestor
    doc = doc_for(<<~HTML)
      <style>
        #outer { color: red }
        #inner { color: blue; background-color: currentColor }
      </style>
      <div id="outer"><span id="inner">x</span></div>
    HTML
    # currentColor uses the *inner* element's own color, not the inherited red.
    assert_equal "rgb(0, 0, 255)", computed(doc, "inner")["background-color"]
  end

  def test_current_color_on_color_property_means_inherit
    doc = doc_for(<<~HTML)
      <style>#outer { color: green } #inner { color: currentColor }</style>
      <div id="outer"><span id="inner">x</span></div>
    HTML
    assert_equal "rgb(0, 128, 0)", computed(doc, "inner")["color"]
  end

  def test_current_color_in_an_expanded_border_longhand
    doc = doc_for('<style>#x { color: red; border: 1px solid currentColor }</style><p id="x">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["border-top-color"]
  end

  # --- shorthand expansion ----------------------------------------------

  def test_border_shorthand_expands_to_all_sides
    doc = doc_for('<style>#x { border: 2px solid red }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "2px", s["border-top-width"]
    assert_equal "solid", s["border-left-style"]
    assert_equal "rgb(255, 0, 0)", s["border-bottom-color"]
  end

  def test_border_shorthand_tokens_are_order_independent
    doc = doc_for('<style>#x { border: red 2px dashed }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "2px", s["border-top-width"]
    assert_equal "dashed", s["border-top-style"]
    assert_equal "rgb(255, 0, 0)", s["border-top-color"]
  end

  def test_border_omitted_color_resets_to_currentcolor
    doc = doc_for('<style>#x { color: blue; border: 1px solid }</style><p id="x">x</p>')
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["border-top-color"]
  end

  def test_border_color_box_expansion
    doc = doc_for('<style>#x { border-color: red green blue }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "rgb(255, 0, 0)", s["border-top-color"]
    assert_equal "rgb(0, 128, 0)", s["border-right-color"]
    assert_equal "rgb(0, 0, 255)", s["border-bottom-color"]
    assert_equal "rgb(0, 128, 0)", s["border-left-color"] # 3-value: left mirrors right
  end

  def test_later_border_shorthand_resets_earlier_longhand
    doc = doc_for('<style>#x { border-color: red; border: 1px solid }</style><p id="x">x</p>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["border-top-color"]
  end

  def test_flex_shorthand
    doc = doc_for('<style>#x { flex: 2 0 30% }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "2", s["flex-grow"]
    assert_equal "0", s["flex-shrink"]
    assert_equal "30%", s["flex-basis"]
  end

  def test_flex_keyword_forms
    none = doc_for('<style>#x { flex: none }</style><p id="x">x</p>')
    assert_equal ["0", "0", "auto"], %w[flex-grow flex-shrink flex-basis].map { |p| computed(none, "x")[p] }
    num = doc_for('<style>#y { flex: 3 }</style><p id="y">y</p>')
    assert_equal ["3", "1", "0%"], %w[flex-grow flex-shrink flex-basis].map { |p| computed(num, "y")[p] }
  end

  def test_list_style_shorthand
    doc = doc_for('<style>#x { list-style: square inside }</style><ul id="x"></ul>')
    s = computed(doc, "x")
    assert_equal "square", s["list-style-type"]
    assert_equal "inside", s["list-style-position"]
    assert_equal "none", s["list-style-image"]
  end

  def test_outline_and_text_decoration_shorthands
    doc = doc_for('<style>#x { outline: thin dashed blue; text-decoration: underline dotted green }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "dashed", s["outline-style"]
    assert_equal "rgb(0, 0, 255)", s["outline-color"]
    assert_equal "underline", s["text-decoration-line"]
    assert_equal "dotted", s["text-decoration-style"]
    assert_equal "rgb(0, 128, 0)", s["text-decoration-color"]
  end

  # --- calc() / min() / max() / clamp() ---------------------------------

  def test_calc_resolves_in_computed_value
    doc = doc_for('<style>#x { font-size: calc(10px + 2px); letter-spacing: calc(2rem - 4px) }</style><p id="x">x</p>')
    s = computed(doc, "x")
    assert_equal "12px", s["font-size"]
    assert_equal "28px", s["letter-spacing"]
  end

  def test_calc_with_viewport_units
    doc = doc_for('<style>#x { letter-spacing: calc(50vw - 10px) }</style><p id="x">x</p>')
    assert_equal "630px", computed(doc, "x")["letter-spacing"] # 1280/2 - 10
  end

  def test_clamp_for_font_size
    doc = doc_for('<style>#x { font-size: clamp(12px, 50vw, 20px) }</style><p id="x">x</p>')
    assert_equal "20px", computed(doc, "x")["font-size"]
  end

  def test_calc_with_percentage_stays_symbolic
    doc = doc_for('<style>#x { letter-spacing: calc(100% - 10px) }</style><p id="x">x</p>')
    assert_equal "calc(100% - 10px)", computed(doc, "x")["letter-spacing"]
  end

  def test_color_values_normalize_to_rgb_serialization
    doc = doc_for('<style>#x { color: rebeccapurple; background-color: #00ff00 }</style><p id="x">x</p>')
    styles = computed(doc, "x")
    assert_equal "rgb(102, 51, 153)", styles["color"]
    assert_equal "rgb(0, 255, 0)", styles["background-color"]
  end

  def test_font_weight_keywords_normalize
    doc = doc_for('<style>#x { font-weight: bold }</style><p id="x">x</p>')
    assert_equal "700", computed(doc, "x")["font-weight"]
  end

  # --- shorthands ----------------------------------------------------

  def test_background_shorthand_sets_and_resets_background_color
    doc = doc_for(<<~HTML)
      <style>
        #a { background: red }
        #b { background-color: red }
        #b { background: url("x.png") }
      </style>
      <div id="a"></div><div id="b"></div>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "a")["background-color"]
    # The later shorthand without a color resets the longhand to its initial.
    assert_equal "rgba(0, 0, 0, 0)", computed(doc, "b")["background-color"]
  end

  def test_font_shorthand_expands
    doc = doc_for('<style>#x { font: italic bold 20px Arial }</style><p id="x">x</p>')
    styles = computed(doc, "x")
    assert_equal "italic", styles["font-style"]
    assert_equal "700", styles["font-weight"]
    assert_equal "20px", styles["font-size"]
    assert_equal "Arial", styles["font-family"]
  end

  def test_unregistered_properties_pass_through_without_inheriting
    doc = doc_for('<style>#x { border-radius: 4px }</style><div id="x"><p id="y">x</p></div>')
    assert_equal "4px", computed(doc, "x")["border-radius"]
    assert_nil computed(doc, "y")["border-radius"]
  end

  # --- invalidation ---------------------------------------------------

  def test_class_change_invalidates_the_computed_style
    doc = doc_for('<style>.hidden { display: none }</style><div id="x">x</div>')
    assert_equal "block", computed(doc, "x")["display"]

    doc.get_element_by_id("x").class_list.add("hidden")
    assert_equal "none", computed(doc, "x")["display"]
  end

  def test_style_element_text_change_invalidates
    doc = doc_for('<style id="sheet">#x { color: red }</style><p id="x">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]

    doc.get_element_by_id("sheet").text_content = "#x { color: blue }"
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_repeated_reads_reuse_the_memo
    doc = doc_for('<style>#x { color: red }</style><p id="x">x</p>')
    first = computed(doc, "x")
    assert_same first, computed(doc, "x")
  end

  # --- CSSOM (CSSStyleSheet) connection --------------------------------

  def test_insert_rule_reaches_the_computed_style
    doc = doc_for('<style></style><p id="t">x</p>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "t")["color"]

    doc.query_selector("style").sheet.insert_rule("#t{color:red}", 0)
    assert_equal "rgb(255, 0, 0)", computed(doc, "t")["color"]
  end

  def test_insert_rule_at_zero_precedes_the_style_text
    doc = doc_for('<style>#t { color: red }</style><p id="t">x</p>')
    sheet = doc.query_selector("style").sheet
    sheet.insert_rule("#t { color: blue }", 0)

    # Equal specificity: the original (now later) rule wins by source order.
    assert_equal "rgb(255, 0, 0)", computed(doc, "t")["color"]

    sheet.insert_rule("#t { color: green }")
    assert_equal "rgb(0, 128, 0)", computed(doc, "t")["color"]
  end

  def test_delete_rule_removes_it_from_the_cascade
    doc = doc_for('<style></style><p id="t">x</p>')
    sheet = doc.query_selector("style").sheet
    sheet.insert_rule("#t{color:red}", 0)
    assert_equal "rgb(255, 0, 0)", computed(doc, "t")["color"]

    sheet.delete_rule(0)
    assert_equal "rgb(0, 0, 0)", computed(doc, "t")["color"]
  end

  def test_disabled_mutes_the_sheet_and_false_restores_it
    doc = doc_for('<style>#t { color: red }</style><p id="t">x</p>')
    sheet = doc.query_selector("style").sheet
    sheet.insert_rule("#t { display: none }", 0)
    assert_equal "none", computed(doc, "t")["display"]

    sheet.disabled = true
    assert_equal "rgb(0, 0, 0)", computed(doc, "t")["color"]
    assert_equal "block", computed(doc, "t")["display"]

    sheet.disabled = false
    assert_equal "rgb(255, 0, 0)", computed(doc, "t")["color"]
    assert_equal "none", computed(doc, "t")["display"]
  end

  def test_sheet_is_memoized_while_the_text_is_unchanged
    doc = doc_for('<style>#t { color: red }</style><p id="t">x</p>')
    style = doc.query_selector("style")
    assert_same style.sheet, style.sheet
  end

  def test_text_rewrite_rebuilds_the_sheet_and_drops_inserted_rules
    doc = doc_for('<style id="s">#t { color: red }</style><p id="t">x</p>')
    style = doc.get_element_by_id("s")
    old_sheet = style.sheet
    old_sheet.insert_rule("#t { display: none }", 0)
    assert_equal "none", computed(doc, "t")["display"]

    style.text_content = "#t { color: blue }"
    refute_same old_sheet, style.sheet
    assert_equal "rgb(0, 0, 255)", computed(doc, "t")["color"]
    assert_equal "block", computed(doc, "t")["display"]
  end

  def test_replace_sync_swaps_the_sheet_contents
    doc = doc_for('<style>#t { color: red }</style><p id="t">x</p>')
    sheet = doc.query_selector("style").sheet
    sheet.replace_sync("#t { color: blue }")
    assert_equal "rgb(0, 0, 255)", computed(doc, "t")["color"]
  end

  # --- @media / viewport (P2) -------------------------------------------

  def test_media_rule_applies_when_condition_matches_default_viewport
    doc = doc_for('<style>@media (min-width: 600px) { #x { display: none } }</style><p id="x">x</p>')
    assert_equal "none", computed(doc, "x")["display"]
  end

  def test_media_rule_skipped_when_condition_fails
    doc = doc_for('<style>@media (min-width: 2000px) { #x { display: none } }</style><p id="x">x</p>')
    assert_equal "block", computed(doc, "x")["display"]
  end

  def test_resize_reevaluates_media_rules
    doc = doc_for('<style>@media (max-width: 600px) { #x { display: none } }</style><p id="x">x</p>')
    assert_equal "block", computed(doc, "x")["display"]

    doc.default_view.resize_to(500, 700)
    assert_equal "none", computed(doc, "x")["display"]

    doc.default_view.resize_to(1280, 720)
    assert_equal "block", computed(doc, "x")["display"]
  end

  def test_nested_media_conditions_are_anded
    doc = doc_for(<<~HTML)
      <style>
        @media screen { @media (min-width: 600px) { #a { display: none } } }
        @media print { @media (min-width: 600px) { #b { display: none } } }
      </style>
      <p id="a">a</p><p id="b">b</p>
    HTML
    assert_equal "none", computed(doc, "a")["display"]
    assert_equal "block", computed(doc, "b")["display"]
  end

  # --- @import ----------------------------------------------------------

  def import_doc(html, sheets)
    doc = doc_for(html)
    doc.css_import_resolver = ->(url) { sheets[url] }
    doc
  end

  def test_import_splices_referenced_rules
    doc = import_doc(
      '<style>@import url(base.css); #x { color: green }</style><p id="x">x</p>',
      "base.css" => "#x { color: red; font-weight: bold }"
    )
    s = computed(doc, "x")
    # imported rules sit at the @import position (before #x{green}), so green
    # wins on source order, but the imported font-weight still applies.
    assert_equal "rgb(0, 128, 0)", s["color"]
    assert_equal "700", s["font-weight"]
  end

  def test_import_is_recursive
    doc = import_doc(
      '<style>@import url(a.css);</style><p id="x">x</p>',
      "a.css" => "@import url(b.css);",
      "b.css" => "#x { color: red }"
    )
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_import_media_query_gates_the_sheet
    doc = import_doc(
      '<style>@import "big.css" (min-width: 9999px);</style><p id="x">x</p>',
      "big.css" => "#x { color: red }"
    )
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
  end

  def test_import_cycle_is_guarded
    doc = import_doc(
      '<style>@import url(a.css);</style><p id="x">x</p>',
      "a.css" => "@import url(a.css); #x { color: red }"
    )
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_import_without_resolver_contributes_nothing
    doc = doc_for('<style>@import url(base.css); #x { color: green }</style><p id="x">x</p>')
    assert_equal "rgb(0, 128, 0)", computed(doc, "x")["color"]
  end

  # --- @layer / @supports -----------------------------------------------

  def test_layer_rules_apply_in_source_order
    doc = doc_for(<<~HTML)
      <style>
        @layer base { #x { color: red } }
        #x { color: green }
      </style>
      <p id="x">x</p>
    HTML
    # @layer is treated as plain source order, so the later unlayered rule wins.
    assert_equal "rgb(0, 128, 0)", computed(doc, "x")["color"]
  end

  def test_supports_block_applies_when_condition_holds
    doc = doc_for('<style>@supports (display: grid) { #x { color: red } }</style><p id="x">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_supports_not_grid_does_not_apply
    doc = doc_for('<style>@supports not (display: grid) { #x { color: red } }</style><p id="x">x</p>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
  end

  def test_supports_and_or_combine
    doc = doc_for(<<~HTML)
      <style>
        @supports (display: grid) and (color: red) { #a { color: red } }
        @supports (display: grid) or (whatever: nope) { #b { color: red } }
      </style>
      <p id="a">a</p><p id="b">b</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "a")["color"]
    assert_equal "rgb(255, 0, 0)", computed(doc, "b")["color"]
  end

  def test_other_at_rules_are_ignored_without_breaking_the_cascade
    doc = doc_for(<<~HTML)
      <style>
        @keyframes spin { from { opacity: 0 } to { opacity: 1 } }
        @font-face { font-family: Foo; src: url(x.woff2) }
        #x { color: red }
      </style>
      <p id="x">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_media_dependent_visibility
    doc = doc_for('<style>@media (max-width: 600px) { #x { display: none } }</style><p id="x">x</p>')
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))

    doc.default_view.resize_to(400, 700)
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
  end

  def test_resize_fires_resize_event_and_mql_change
    doc = doc_for('<p id="x">x</p>')
    win = doc.default_view
    mql = win.__js_call__("matchMedia", ["(min-width: 600px)"])
    assert mql.matches

    changes = []
    resized = 0
    mql.add_event_listener("change", proc { |e| changes << e.matches })
    win.add_event_listener("resize", proc { resized += 1 })

    win.resize_to(500, 700)
    refute mql.matches
    assert_equal [false], changes
    assert_equal 1, resized

    # No flip, no change event.
    win.resize_to(400, 700)
    assert_equal [false], changes
    assert_equal 2, resized
  end

  def test_viewport_defaults_and_js_access
    win = doc_for("<p>x</p>").default_view
    assert_equal 1280, win.inner_width
    assert_equal 720, win.__js_get__("innerHeight")
    assert_equal 1.0, win.__js_get__("devicePixelRatio")
  end

  # --- visible? integration --------------------------------------------

  def test_visible_detects_class_based_display_none
    doc = doc_for('<style>.hidden { display: none }</style><p id="x" class="hidden">x</p>')
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
  end

  def test_visible_detects_ancestor_class_based_display_none
    doc = doc_for('<style>.hidden { display: none }</style><div class="hidden"><p id="x">x</p></div>')
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
  end

  def test_visible_detects_class_based_visibility_hidden_with_override
    doc = doc_for(<<~HTML)
      <style>.quiet { visibility: hidden } .loud { visibility: visible }</style>
      <div class="quiet"><p id="hidden">x</p><p id="shown" class="loud">x</p></div>
    HTML
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("hidden"))
    # visibility is overridable by a descendant, unlike display:none.
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("shown"))
  end

  def test_visible_treats_zero_opacity_as_invisible
    doc = doc_for(<<~HTML)
      <style>.ghost { opacity: 0 } .faint { opacity: 0.5 } .zero-pct { opacity: 0% }</style>
      <p id="ghost" class="ghost">x</p>
      <div class="ghost"><p id="nested">x</p></div>
      <p id="faint" class="faint">x</p>
      <p id="pct" class="zero-pct">x</p>
    HTML
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("ghost"))
    # Zero anywhere in the ancestor chain zeroes the effective opacity.
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("nested"))
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("faint"))
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("pct"))
  end

  def test_visible_keeps_the_fast_path_for_sheetless_documents
    doc = doc_for('<p id="x" class="hidden">x</p>')
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
    refute Dommy::Internal::DomMatching.visible?(
      Dommy.parse('<p id="y" style="display: none">x</p>').document.get_element_by_id("y")
    )
  end

  # --- review-fix regressions -------------------------------------------

  def test_style_media_attribute_gates_the_sheet
    doc = doc_for('<style media="(max-width: 100px)">#x { color: red }</style><p id="x">x</p>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]

    doc.default_view.resize_to(80, 600)
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_selector_list_mixing_element_and_pseudo_element_branches
    doc = doc_for('<style>div, ::before { color: red }</style><div id="d">x</div>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "d")["color"]
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("d"), "::before")
    assert_equal "rgb(255, 0, 0)", declaration["color"]
  end

  def test_detached_elements_have_an_empty_computed_style
    doc = doc_for("<p>x</p>")
    detached = doc.create_element("div")
    assert_equal({}, CASCADE.computed_style(detached))
    assert_equal "", doc.default_view.get_computed_style(detached)["display"]
  end

  def test_inline_important_with_space_before_the_keyword
    doc = doc_for(<<~HTML)
      <style>#x { color: blue !important }</style>
      <p id="x" style="color: red ! important">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_inline_zero_opacity_hides_even_without_author_css
    doc = doc_for('<p id="x" style="opacity: 0">x</p><p id="y" style="opacity: 0.5">y</p>')
    refute Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("y"))
  end

  # --- getComputedStyle ------------------------------------------------

  def test_window_get_computed_style_returns_a_read_only_declaration
    doc = doc_for('<style>.hidden { display: none }</style><div id="x" class="hidden">x</div>')
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("x"))

    assert_equal "none", declaration.get_property_value("display")
    assert_equal "none", declaration["display"]
    assert_raises(Dommy::DOMException::NoModificationAllowedError) do
      declaration.set_property("color", "red")
    end
  end

  def test_get_computed_style_is_live_across_mutations
    doc = doc_for('<style>.hidden { display: none }</style><div id="x">x</div>')
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("x"))
    assert_equal "block", declaration["display"]

    doc.get_element_by_id("x").class_list.add("hidden")
    assert_equal "none", declaration["display"]
  end

  def test_get_computed_style_with_pseudo_element_reflects_cascade
    doc = doc_for('<style>#x { color: blue } #x::before { color: red; content: "!" }</style><p id="x">x</p>')
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("x"), "::before")
    assert_equal "rgb(255, 0, 0)", declaration.get_property_value("color")
    assert_equal "\"!\"", declaration.get_property_value("content")
  end

  # A pseudo-element rule (which the lexbor binding surfaces as :bad_style for
  # Dommy to re-validate) must not leak onto the element it qualifies.
  def test_pseudo_element_rule_does_not_apply_to_the_element
    doc = doc_for('<style>p { color: red } p::before { color: blue; content: "x" }</style><p id="x">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  # A genuinely invalid selector that lexbor rejects is dropped by Dommy's
  # re-validation (not silently applied).
  def test_invalid_selector_rule_is_dropped
    doc = doc_for('<style>p { color: red } p:totally-unknown-pseudo { color: green }</style><p id="x">x</p>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_js_bridge_get_computed_style
    doc = doc_for('<style>#x { color: red }</style><p id="x">x</p>')
    declaration = doc.default_view.__js_call__("getComputedStyle", [doc.get_element_by_id("x")])

    assert_equal "rgb(255, 0, 0)", declaration.__js_call__("getPropertyValue", ["color"])
    assert_equal "rgb(255, 0, 0)", declaration.__js_get__("color")
  end
end
