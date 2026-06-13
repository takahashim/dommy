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
end
