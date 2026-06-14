# frozen_string_literal: true

require_relative "test_helper"

# Driver#find_by_role / #all_by_role / #has_role? (and Interaction::RoleQuery).
class TestRoleQuery < Minitest::Test
  include DommyTestHelper

  def driver_for(html)
    win = make_window(html)
    driver = Object.new.extend(Dommy::Interaction::Driver)
    driver.define_singleton_method(:document) { win.document }
    driver
  end

  PAGE = <<~HTML
    <header><h1>Articles</h1><h2>Latest</h2></header>
    <main>
      <button>Save</button>
      <button>Save draft</button>
      <a href="/edit">Edit</a>
      <button aria-hidden="true">Ghost</button>
      <button style="display:none">Hidden</button>
    </main>
  HTML

  def test_find_by_role_with_exact_name
    driver = driver_for(PAGE)
    el = driver.find_by_role("button", name: "Save", exact: true)
    assert_equal "Save", el.text_content
  end

  def test_substring_name_is_ambiguous
    driver = driver_for(PAGE)
    # "Save" is a substring of both "Save" and "Save draft".
    assert_raises(Dommy::Interaction::AmbiguousElementError) { driver.find_by_role("button", name: "Save") }
  end

  def test_all_by_role_excludes_hidden
    driver = driver_for(PAGE)
    names = driver.all_by_role("button").map(&:text_content)
    assert_equal ["Save", "Save draft"], names # aria-hidden + display:none excluded
  end

  def test_find_by_role_regex_name
    driver = driver_for(PAGE)
    assert_equal "Edit", driver.find_by_role("link", name: /Ed/).text_content
  end

  def test_find_by_role_level
    driver = driver_for(PAGE)
    assert_equal "Articles", driver.find_by_role("heading", level: 1).text_content
    assert_equal "Latest", driver.find_by_role("heading", level: 2).text_content
  end

  def test_has_role
    driver = driver_for(PAGE)
    assert driver.has_role?("link", name: "Edit")
    refute driver.has_role?("checkbox")
    assert driver.has_no_role?("checkbox")
  end

  def test_not_found_lists_available_roles
    driver = driver_for(PAGE)
    error = assert_raises(Dommy::Interaction::ElementNotFoundError) { driver.find_by_role("checkbox") }
    assert_includes error.message, 'no element with role "checkbox"'
    assert_includes error.message, "Available roles:"
    assert_includes error.message, 'button "Save"'
  end
end
