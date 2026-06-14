# frozen_string_literal: true

require_relative "test_helper"

# Element#computed_role — the WAI-ARIA computed role (getByRole / WPT
# get_computed_role). Covers explicit roles, implicit HTML mappings, synonyms,
# name-required roles, and presentation conflict resolution.
class TestAriaRole < Minitest::Test
  include DommyTestHelper

  def role_of(html, selector)
    make_window(html).document.query_selector(selector).computed_role
  end

  def test_explicit_valid_role_wins
    assert_equal "group", role_of('<div role="group"></div>', "div")
  end

  def test_invalid_explicit_role_falls_back_to_implicit
    assert_equal "navigation", role_of('<nav role="bogus"></nav>', "nav")
  end

  def test_abstract_role_is_ignored
    # "widget" is abstract — the implicit <button> role applies instead.
    assert_equal "button", role_of('<button role="widget"></button>', "button")
  end

  def test_implicit_roles
    cases = {
      "<h1>x</h1>" => ["h1", "heading"],
      "<nav></nav>" => ["nav", "navigation"],
      "<ul><li>x</li></ul>" => ["li", "listitem"],
      '<a href="#">x</a>' => ["a", "link"],
      "<a>x</a>" => ["a", "generic"],
      '<input type="checkbox">' => ["input", "checkbox"],
      "<input>" => ["input", "textbox"],
      "<select></select>" => ["select", "combobox"],
      '<select multiple></select>' => ["select", "listbox"]
    }
    cases.each do |html, (sel, expected)|
      assert_equal expected, role_of(html, sel), "#{html} -> #{sel}"
    end
  end

  def test_header_is_banner_at_top_level_but_generic_when_sectioned
    assert_equal "banner", role_of("<header>x</header>", "header")
    assert_equal "generic", role_of("<article><header>x</header></article>", "article header")
  end

  def test_region_requires_accessible_name
    assert_equal "region", role_of('<section aria-label="n"></section>', "section")
    # Explicit region without a name falls back to the implicit role.
    assert_equal "navigation", role_of('<nav role="region"></nav>', "nav")
  end

  def test_form_requires_accessible_name
    assert_equal "form", role_of('<form aria-label="n"></form>', "form")
    # An unnamed form is not a landmark — it is generic.
    assert_equal "generic", role_of("<form></form>", "form")
  end

  def test_role_fallback_picks_first_valid_token
    assert_equal "group", role_of('<div role="bogus group"></div>', "div")
  end

  def test_synonym_roles_normalize_to_canonical
    assert_equal "list", role_of('<ul role="directory"></ul>', "ul")
  end

  def test_presentation_yields_to_implicit_when_focusable
    # role=none on a focusable element is overridden by the implicit role.
    assert_equal "none", role_of('<span role="none"></span>', "span")
    assert_equal "button", role_of('<button role="none" tabindex="0"></button>', "button")
  end

  def test_img_empty_alt_is_canonical_none
    assert_equal "none", role_of('<img alt="" src="x">', "img")
    assert_equal "img", role_of('<img alt="cat" src="x">', "img")
  end

  def test_details_is_group
    assert_equal "group", role_of("<details><summary>s</summary></details>", "details")
  end

  def test_th_scope
    # Explicit scope wins.
    assert_equal "rowheader", role_of('<table><tr><th scope="row">H</th></tr></table>', "th")
    assert_equal "columnheader", role_of('<table><tr><th scope="col">H</th></tr></table>', "th")
    # Auto: a th bordering a <td> in its row heads that row; a th with only
    # header neighbours heads its column.
    assert_equal "rowheader", role_of("<table><tr><th>H</th><td>d</td></tr></table>", "th")
    assert_equal "rowheader", role_of("<table><tr><td>d</td><th>H</th></tr></table>", "th")
    assert_equal "columnheader", role_of("<table><tr><th>A</th><th>B</th></tr></table>", "th:first-child")
    # In `th th td`, the header bordering the data cell is the row header.
    cols = make_window("<table><tr><th>A</th><th>B</th><td>d</td></tr></table>").document.query_selector_all("th")
    assert_equal "columnheader", cols[0].computed_role
    assert_equal "rowheader", cols[1].computed_role
  end
end
