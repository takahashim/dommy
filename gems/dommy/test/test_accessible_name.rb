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

  # ---- CSS ::before / ::after generated content (accname folds it in) ----

  def test_name_from_content_includes_pseudo_content
    html = '<style>button::before{content:"★ "}button::after{content:" (!)"}</style>' \
           "<button>Save</button>"
    assert_equal "★ Save (!)", label_of(html, "button")
  end

  # A CSS hex escape (`\2605` = ★) terminated by one space: the space delimits
  # the escape, so the string is just "★" — the matcher must decode it.
  def test_pseudo_content_decodes_css_hex_escape
    html = '<style>button::before{content:"\2605 OK"}</style><button>Go</button>'
    assert_equal "★OKGo", label_of(html, "button")
  end

  def test_pseudo_content_resolves_attr
    html = '<style>.req::after{content:" " attr(data-mark)}</style>' \
           '<a href="#" role="link" class="req" data-mark="required">Email</a>'
    assert_equal "Email required", label_of(html, "a")
  end

  def test_pseudo_content_ignores_counter_and_url
    html = '<style>button::before{content:counter(n)}button::after{content:url(x.png)}</style>' \
           "<button>X</button>"
    assert_equal "X", label_of(html, "button")
  end

  def test_aria_label_still_wins_over_pseudo_content
    html = '<style>button::before{content:"PSEUDO "}</style>' \
           '<button aria-label="Explicit">Save</button>'
    assert_equal "Explicit", label_of(html, "button")
  end
end
