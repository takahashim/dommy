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

  def test_visible_keeps_the_fast_path_for_sheetless_documents
    doc = doc_for('<p id="x" class="hidden">x</p>')
    assert Dommy::Internal::DomMatching.visible?(doc.get_element_by_id("x"))
    refute Dommy::Internal::DomMatching.visible?(
      Dommy.parse('<p id="y" style="display: none">x</p>').document.get_element_by_id("y")
    )
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

  def test_get_computed_style_with_pseudo_element_is_empty
    doc = doc_for('<style>#x::before { content: "!" }</style><p id="x">x</p>')
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("x"), "::before")
    assert_equal "", declaration.get_property_value("content")
    assert_equal 0, declaration.length
  end

  def test_js_bridge_get_computed_style
    doc = doc_for('<style>#x { color: red }</style><p id="x">x</p>')
    declaration = doc.default_view.__js_call__("getComputedStyle", [doc.get_element_by_id("x")])

    assert_equal "rgb(255, 0, 0)", declaration.__js_call__("getPropertyValue", ["color"])
    assert_equal "rgb(255, 0, 0)", declaration.__js_get__("color")
  end
end
