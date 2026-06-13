# frozen_string_literal: true

require_relative "test_helper"

# Element#computed_label — the WAI-ARIA accessible name (getByRole name option /
# WPT get_computed_label). Covers the precedence chain and name-from-content.
class TestAccessibleName < Minitest::Test
  include DommyTestHelper

  def label_of(html, selector)
    make_window(html).document.query_selector(selector).computed_label
  end

  def test_aria_label_wins
    assert_equal "the label", label_of('<button aria-label="the label">x</button>', "button")
  end

  def test_aria_labelledby_joins_referenced_text
    html = '<div role="group" aria-labelledby="a b"></div><span id="a">foo</span><span id="b">bar</span>'
    assert_equal "foo bar", label_of(html, "div[role=group]")
  end

  def test_aria_labelledby_self_reference_uses_own_label
    html = '<div role="group" id="g" aria-label="self" aria-labelledby="g h"></div><span id="h">heading</span>'
    assert_equal "self heading", label_of(html, "#g")
  end

  def test_name_from_content_only_for_permitting_roles
    assert_equal "click me", label_of("<button>click me</button>", "button")
    # group does not take its name from content; falls back to the title.
    assert_equal "tip", label_of('<div role="group" title="tip">contents</div>', "div[role=group]")
  end

  def test_name_from_content_preserves_nested_whitespace
    html = "<button id='b'>button<span><span> </span></span>label</button>"
    assert_equal "button label", make_window(html).document.get_element_by_id("b").computed_label.gsub(/\s+/, " ")
  end

  def test_img_alt_and_title_fallback
    assert_equal "a cat", label_of('<img alt="a cat" src="x">', "img")
    assert_equal "tip", label_of('<img title="tip" src="x">', "img")
  end

  def test_native_label_element
    assert_equal "Name", label_of('<label for="i">Name</label><input id="i">', "input")
    assert_equal "Wrapped", label_of("<label>Wrapped<input></label>", "input")
  end

  def test_fieldset_legend_and_table_caption
    assert_equal "Legend", label_of("<fieldset><legend>Legend</legend></fieldset>", "fieldset")
    assert_equal "Cap", label_of("<table><caption>Cap</caption></table>", "table")
  end
end
