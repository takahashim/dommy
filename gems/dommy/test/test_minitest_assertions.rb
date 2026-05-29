# frozen_string_literal: true

require_relative "test_helper"
require "dommy/minitest/assertions"

class TestMinitestAssertions < Minitest::Test
  include DommyTestHelper
  include Dommy::Minitest::Assertions

  def setup
    @win = make_window(
      <<~HTML
        <article class="post featured">
          <h1>Hello</h1>
          <button type="submit" class="primary" disabled>Submit</button>
          <ul>
            <li>One</li>
            <li>Two</li>
            <li>Three</li>
          </ul>
        </article>
      HTML
    )
    @dom = @win.document
    @article = @dom.query_selector("article")
    @button = @dom.query_selector("button")
  end

  # --- assert_dom_contains --------------------------------------------

  def test_assert_dom_contains_existing
    assert_dom_contains(@dom, "button.primary")
  end

  def test_assert_dom_contains_with_count
    assert_dom_contains(@dom, "li", count: 3)
  end

  def test_assert_dom_contains_with_range_count
    assert_dom_contains(@dom, "li", count: 1..5)
  end

  def test_assert_dom_contains_with_text
    assert_dom_contains(@dom, "h1", text: "Hello")
  end

  def test_assert_dom_contains_fails_when_missing
    assert_raises(Minitest::Assertion) do
      assert_dom_contains(@dom, "button.danger")
    end
  end

  def test_assert_dom_contains_fails_when_count_mismatch
    assert_raises(Minitest::Assertion) do
      assert_dom_contains(@dom, "li", count: 5)
    end
  end

  def test_refute_dom_contains
    refute_dom_contains(@dom, "form")
    refute_dom_contains(@dom, "li", count: 5)
  end

  # --- assert_dom_contains_text ---------------------------------------

  def test_assert_dom_contains_text
    assert_dom_contains_text(@dom, "Submit")
    assert_dom_contains_text(@dom, /Hell/)
  end

  def test_assert_dom_contains_text_fails
    assert_raises(Minitest::Assertion) do
      assert_dom_contains_text(@dom, "Cancel")
    end
  end

  def test_refute_dom_contains_text
    refute_dom_contains_text(@dom, "Cancel")
  end

  # --- assert_dom_has_attribute ---------------------------------------

  def test_assert_dom_has_attribute_existence
    assert_dom_has_attribute(@button, "disabled")
  end

  def test_assert_dom_has_attribute_with_value
    assert_dom_has_attribute(@button, "type", "submit")
  end

  def test_assert_dom_has_attribute_fails_for_missing
    assert_raises(Minitest::Assertion) do
      assert_dom_has_attribute(@button, "name")
    end
  end

  def test_refute_dom_has_attribute
    refute_dom_has_attribute(@button, "name")
  end

  # --- assert_dom_has_class -------------------------------------------

  def test_assert_dom_has_class
    assert_dom_has_class(@button, "primary")
    assert_dom_has_class(@article, "featured")
  end

  def test_assert_dom_has_class_fails
    assert_raises(Minitest::Assertion) do
      assert_dom_has_class(@button, "danger")
    end
  end

  def test_refute_dom_has_class
    refute_dom_has_class(@button, "danger")
  end

  # --- assert_dom_html_equal ------------------------------------------

  def test_assert_dom_html_equal_ignores_whitespace
    el = @dom.query_selector("h1")
    assert_dom_html_equal(el, "Hello")
  end

  def test_assert_dom_html_equal_fails_on_diff
    el = @dom.query_selector("h1")
    assert_raises(Minitest::Assertion) do
      assert_dom_html_equal(el, "Goodbye")
    end
  end
end
