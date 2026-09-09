# frozen_string_literal: true

require_relative "../test_helper"

# Three divergences the dommy-conformance differential harness found by running
# the same JavaScript in headless Chromium and in Dommy. None of them is covered
# by WPT, which is why they survived this long.
#
# https://github.com/takahashim/dommy-conformance

# Cascade order applies WITHIN one declaration block, not just between blocks:
# an important declaration beats a normal one for the same property whatever
# their order, and only equal importance lets the later win.
#
# WPT: css/cssom/cssstyledeclaration-csstext-important.html (the shorthand form
#      of the same rule)
# Spec: https://drafts.csswg.org/css-cascade/#importance
class TestWPTImportantWithinADeclarationBlock < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @el = @doc.create_element("div")
  end

  def css_text_after(source)
    @el.style.css_text = source
    @el.style.css_text
  end

  def test_a_later_normal_declaration_does_not_displace_an_important_one
    assert_equal("color: red !important;", css_text_after("color: red !important; color: blue"))
    assert_equal("important", @el.style.get_property_priority("color"))
    assert_equal("red", @el.style.get_property_value("color"))
  end

  def test_a_later_important_declaration_does_win
    assert_equal("color: blue !important;", css_text_after("color: red !important; color: blue !important"))
  end

  def test_an_important_declaration_after_a_normal_one_wins
    assert_equal("color: red !important;", css_text_after("color: blue; color: red !important"))
  end

  def test_between_two_normal_declarations_the_later_wins
    assert_equal("color: blue;", css_text_after("color: red; color: blue"))
  end

  # The surviving declaration keeps the position it was first written at, so the
  # serialization order still follows the source.
  def test_the_kept_declaration_stays_in_its_original_position
    @el.style.css_text = "color: red !important; width: 1px; color: blue"
    assert_equal("color: red !important; width: 1px;", @el.style.css_text)
  end

  def test_a_stylesheet_rules_block_follows_the_same_rule
    document = Dommy.parse("<style>p { color: red !important; color: blue }</style>").document
    style = document.query_selector("style").sheet.css_rules[0].style
    assert_equal("red", style.get_property_value("color"))
    assert_equal("important", style.get_property_priority("color"))
  end
end

# A text-like control "suffers from being missing" only while it is MUTABLE, and
# a control inside a disabled <fieldset> is not — even though it carries no
# disabled attribute of its own. willValidate already knew about the ancestor;
# the mutability check behind valueMissing did not.
#
# WPT: html/semantics/forms/constraints/form-validation-validity-valueMissing.html
# Spec: https://html.spec.whatwg.org/multipage/#the-constraint-validation-api
class TestWPTValueMissingAndMutability < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <form>
        <input id="plain" required>
        <input id="own-disabled" required disabled>
        <input id="readonly" required readonly>
        <fieldset disabled>
          <input id="in-fieldset" required>
          <input id="checkbox-in-fieldset" type="checkbox" required>
          <select id="select-in-fieldset" required><option value="">pick</option></select>
        </fieldset>
      </form>
    HTML
    @doc = @win.document
  end

  def control(id) = @doc.get_element_by_id(id)

  def test_a_mutable_required_control_is_missing
    assert(control("plain").will_validate)
    assert(control("plain").validity.value_missing)
  end

  def test_a_directly_disabled_control_is_not_missing
    refute(control("own-disabled").will_validate)
    refute(control("own-disabled").validity.value_missing)
  end

  def test_a_readonly_control_is_not_missing
    refute(control("readonly").validity.value_missing)
  end

  # The regression: barred by an ancestor rather than by its own attribute.
  def test_a_control_disabled_by_a_fieldset_ancestor_is_not_missing
    input = control("in-fieldset")
    refute(input.will_validate, "willValidate already accounted for the fieldset")
    refute(input.validity.value_missing, "valueMissing must use the same 'actually disabled' state")
    assert(input.check_validity)
  end

  # Only the text-like definition carries the mutability condition. A checkbox
  # suffers from being missing on checkedness alone, so it still reports the
  # flag while barred — WPT pins exactly this ("validationMessage should return
  # empty string when willValidate is false and valueMissing is true").
  def test_a_checkbox_in_a_disabled_fieldset_is_still_missing
    checkbox = control("checkbox-in-fieldset")
    refute(checkbox.will_validate)
    assert(checkbox.validity.value_missing)
    assert_equal("", checkbox.validation_message)
  end

  def test_a_select_in_a_disabled_fieldset_is_still_missing
    select = control("select-in-fieldset")
    refute(select.will_validate)
    assert(select.validity.value_missing)
  end
end

# Range.insertNode splits its start Text node UNCONDITIONALLY — including at
# offset 0 and at the node's end, where the split leaves an empty Text node
# beside the inserted one — and a collapsed range then grows to contain what was
# inserted.
#
# WPT: dom/ranges/Range-insertNode.html (unrunnable here: it drives iframes)
# Spec: https://dom.spec.whatwg.org/#concept-range-insert
class TestWPTRangeInsertNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='d'><p id='p'>hello world</p></div>")
    @doc = @win.document
  end

  def paragraph = @doc.get_element_by_id("p")

  def children
    paragraph.child_nodes.to_a.map { |n| n.respond_to?(:data) ? n.data : n.local_name }
  end

  def insert_collapsed_at(offset)
    range = @doc.create_range
    range.set_start(paragraph.first_child, offset)
    range.collapse(true)
    range.insert_node(@doc.create_element("b"))
    range
  end

  def test_an_interior_offset_splits_and_the_range_grows_over_the_node
    range = insert_collapsed_at(5)
    assert_equal(["hello", "b", " world"], children)
    assert_equal(5, range.start_offset)
    assert_same(paragraph, range.end_container)
    assert_equal(2, range.end_offset)
    refute(range.collapsed?)
  end

  # The split happens at offset 0 too, so an EMPTY Text node precedes the
  # inserted one. Skipping the split there is the tempting optimization and it
  # produces a different tree.
  def test_offset_zero_still_splits_and_leaves_an_empty_text_node
    range = insert_collapsed_at(0)
    assert_equal(["", "b", "hello world"], children)
    assert_equal(0, range.start_offset)
    assert_equal(2, range.end_offset)
  end

  def test_an_offset_at_the_end_leaves_the_empty_text_node_after
    range = insert_collapsed_at(11)
    assert_equal(["hello world", "b", ""], children)
    assert_equal(11, range.start_offset)
    assert_equal(2, range.end_offset)
  end

  # Only a COLLAPSED range is grown; a range with content keeps the end the
  # split gave it.
  def test_a_non_collapsed_range_keeps_its_end
    range = @doc.create_range
    range.set_start(paragraph.first_child, 5)
    range.set_end(paragraph.first_child, 8)
    range.insert_node(@doc.create_element("b"))
    assert_equal(["hello", "b", " world"], children)
    assert_equal([5, 3], [range.start_offset, range.end_offset])
    refute(range.collapsed?)
  end

  def test_an_element_container_inserts_at_the_child_offset
    div = @doc.get_element_by_id("d")
    div.inner_html = "<a></a><i></i>"
    range = @doc.create_range
    range.set_start(div, 1)
    range.collapse(true)
    range.insert_node(@doc.create_element("b"))
    assert_equal(%w[a b i], div.child_nodes.to_a.map(&:local_name))
    assert_equal([1, 2], [range.start_offset, range.end_offset])
  end

  # A DocumentFragment contributes each of its children to the new end offset.
  def test_a_fragment_advances_the_end_by_its_length
    div = @doc.get_element_by_id("d")
    div.inner_html = "<a></a>"
    fragment = @doc.create_document_fragment
    fragment.append(@doc.create_element("x"), @doc.create_element("y"))
    range = @doc.create_range
    range.set_start(div, 0)
    range.collapse(true)
    range.insert_node(fragment)
    assert_equal(%w[x y a], div.child_nodes.to_a.map(&:local_name))
    assert_equal([0, 2], [range.start_offset, range.end_offset])
  end
end
