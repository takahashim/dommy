# frozen_string_literal: true

require_relative "test_helper"

# The split invalidation epochs (perf-roadmap / D1b): dom_generation keys the
# selector-result caches, style_generation the cascade caches. A style-neutral
# mutation must leave the cascade caches warm — and every mutation that CAN
# change a match or a computed style must still invalidate. Correctness is
# asserted through observable behavior (fresh query results / computed
# values); cache retention through the computed Hash's identity (the cascade
# memo returns the same frozen Hash while its cache is warm).
class TestCssInvalidation < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade

  def doc_for(html)
    Dommy.parse(html).document
  end

  def computed(doc, id)
    CASCADE.computed_style(doc.get_element_by_id(id))
  end

  # --- cascade cache retention (style-neutral mutations) ---------------

  def test_character_data_edit_keeps_computed_style_cache
    doc = doc_for('<style>.a { color: red }</style><div class="a" id="x">hi</div>')
    before = computed(doc, "x")
    doc.get_element_by_id("x").first_child.data = "changed"
    assert_same before, computed(doc, "x")
  end

  def test_unreferenced_attribute_change_keeps_computed_style_cache
    doc = doc_for('<style>.a { color: red }</style><div class="a" id="x">hi</div>')
    before = computed(doc, "x")
    doc.get_element_by_id("x").set_attribute("data-n", "1")
    assert_same before, computed(doc, "x")
  end

  # --- cascade cache invalidation (style-affecting mutations) ----------

  def test_class_change_recomputes_styles
    doc = doc_for('<style>.a { color: red } .b { color: blue }</style><div class="a" id="x">hi</div>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").set_attribute("class", "b")
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_sheet_referenced_attribute_change_recomputes_styles
    doc = doc_for('<style>[data-on] { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").set_attribute("data-on", "")
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_style_attribute_change_recomputes_styles
    doc = doc_for('<style>.a { color: red }</style><div class="a" id="x">hi</div>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").set_attribute("style", "color: blue")
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_style_element_text_edit_recomputes_styles
    doc = doc_for('<style>#x { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
    doc.query_selector("style").first_child.data = "#x { color: blue }"
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_media_attribute_on_style_element_recomputes_styles
    doc = doc_for('<style id="s">#x { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("s").set_attribute("media", "print")
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
  end

  def test_empty_flip_recomputes_styles_when_sheet_uses_empty
    doc = doc_for('<style>div:empty { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").first_child.data = ""
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  RULE_INDEX = Dommy::Internal::CSS::RuleIndex

  # Drift guard (see the Q3 fix): a pseudo whose match depends on descendant
  # text MUST be in TEXT_SENSITIVE_PSEUDOS, or a text edit won't recompute the
  # cascade. :empty is the one the matcher reads text for today; when :blank
  # (already reserved in the set) or another gains a text-reading match, add a
  # case here so this guard covers it.
  def test_text_reading_pseudos_mark_the_index_text_sensitive
    %w[empty].each do |pseudo|
      doc = doc_for("<style>div:#{pseudo} { color: red }</style><div id=\"x\">hi</div>")
      idx = CASCADE.index_for(doc)
      assert idx.text_sensitive?, ":#{pseudo} must be in RuleIndex::TEXT_SENSITIVE_PSEUDOS"
    end
  end

  # The dependency maps must reference only real pseudo-class names (a typo
  # would silently never match, collapsing to the all-attrs fallback).
  def test_dependency_maps_reference_only_known_pseudos
    known = Dommy::Internal::KNOWN_PSEUDOS
    names = RULE_INDEX::PSEUDO_CLASS_ATTR_DEPS.keys +
      RULE_INDEX::TEXT_SENSITIVE_PSEUDOS + RULE_INDEX::NTH_PSEUDOS
    names.each { |name| assert_includes known, name, "#{name.inspect} is not a known pseudo-class" }
  end

  # An unmapped pseudo (all-attributes fallback) appearing BEFORE an :empty
  # rule must not hide the :empty from text-sensitivity — the two are
  # independent invalidation axes, so a text edit still recomputes.
  def test_all_attr_fallback_does_not_suppress_empty_text_sensitivity
    doc = doc_for('<style>a:defined { color: blue } div:empty { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").first_child.data = ""
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_unmapped_pseudo_class_falls_back_to_any_attribute
    doc = doc_for('<style>input:invalid { color: red }</style><input id="x" type="text">')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").set_attribute("required", "")
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_has_argument_attributes_are_dependencies
    doc = doc_for('<style>div:has([data-flag]) { color: red }</style><div id="x"><span id="y">hi</span></div>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("y").set_attribute("data-flag", "")
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_child_list_mutation_recomputes_styles
    doc = doc_for('<style>div:empty { color: red }</style><div id="x">hi</div>')
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").first_child.remove
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  # --- query-result cache (dom_generation) ------------------------------

  def test_empty_flip_refreshes_query_results
    doc = doc_for("<div id=\"x\">hi</div>")
    assert_nil doc.query_selector("div:empty")
    doc.get_element_by_id("x").first_child.data = ""
    refute_nil doc.query_selector("div:empty")
  end

  def test_attribute_change_refreshes_query_results
    doc = doc_for("<div id=\"x\">hi</div>")
    assert_nil doc.query_selector("[data-n]")
    doc.get_element_by_id("x").set_attribute("data-n", "1")
    refute_nil doc.query_selector("[data-n]")
  end

  def test_checkedness_refreshes_query_results_and_styles
    doc = doc_for('<style>input:checked { color: red }</style><input type="checkbox" id="x">')
    assert_nil doc.query_selector(":checked")
    assert_equal "rgb(0, 0, 0)", computed(doc, "x")["color"]
    doc.get_element_by_id("x").checked = true
    refute_nil doc.query_selector(":checked")
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_comment_data_edit_bumps_no_generation
    doc = doc_for("<div id=\"x\">hi</div><!--c-->")
    dom_before = doc.dom_generation
    style_before = doc.style_generation
    comment = doc.get_element_by_id("x").next_sibling
    comment.data = "changed"
    assert_equal dom_before, doc.dom_generation
    assert_equal style_before, doc.style_generation
  end

  def test_non_flipping_text_edit_bumps_no_generation
    doc = doc_for("<div id=\"x\">hi</div>")
    doc.query_selector(".warm-up")
    dom_before = doc.dom_generation
    style_before = doc.style_generation
    doc.get_element_by_id("x").first_child.data = "ho"
    assert_equal dom_before, doc.dom_generation
    assert_equal style_before, doc.style_generation
  end

  # --- IDL value changes (no attribute mutation behind them) -----------

  # `input.value =` mutates no attribute, yet :invalid / :in-range /
  # :placeholder-shown all read it. Without a selector-epoch bump a cached
  # querySelectorAll survives the very change that flipped its result.
  def test_value_assignment_refreshes_cached_selector_results
    doc = doc_for('<input id="i" required>')
    assert_equal 1, doc.query_selector_all(":invalid").length

    doc.get_element_by_id("i").value = "filled"
    assert_equal 0, doc.query_selector_all(":invalid").length

    doc.get_element_by_id("i").value = ""
    assert_equal 1, doc.query_selector_all(":invalid").length
  end

  def test_value_assignment_invalidates_a_value_sensitive_cascade
    doc = doc_for('<style>input:invalid { color: red }</style><input id="i" required>')
    assert_equal "rgb(255, 0, 0)", computed(doc, "i")["color"]

    doc.get_element_by_id("i").value = "filled"
    refute_equal "rgb(255, 0, 0)", computed(doc, "i")["color"]
  end

  def test_a_textarea_value_assignment_refreshes_selector_results
    doc = doc_for("<textarea id=\"t\" required></textarea>")
    assert_equal 1, doc.query_selector_all(":invalid").length
    doc.get_element_by_id("t").value = "filled"
    assert_equal 0, doc.query_selector_all(":invalid").length
  end

  # The cascade half is gated: a sheet that reads no value-sensitive
  # pseudo-class keeps its computed styles across a value assignment.
  def test_value_assignment_keeps_a_value_neutral_cascade_warm
    doc = doc_for('<style>.a { color: red }</style><input id="i" class="a" required>')
    before = computed(doc, "i")
    doc.get_element_by_id("i").value = "filled"
    assert_same before, computed(doc, "i")
  end

  def test_a_form_reset_refreshes_selector_results
    doc = doc_for('<form id="f"><input id="i" required></form>')
    doc.get_element_by_id("i").value = "filled"
    assert_equal 0, doc.query_selector_all("input:invalid").length

    doc.get_element_by_id("f").reset
    assert_equal 1, doc.query_selector_all("input:invalid").length
  end
end
