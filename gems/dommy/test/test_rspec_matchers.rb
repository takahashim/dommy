# frozen_string_literal: true

require_relative "test_helper"
require "dommy/rspec/matchers"

# Tests RSpec matcher classes by calling matches? directly.
# This avoids a hard dependency on the rspec gem itself; the matcher
# protocol (matches?, failure_message, etc.) is what RSpec consumes.
class TestRSpecMatchers < Minitest::Test
  include DommyTestHelper
  include Dommy::RSpec::Matchers

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

  # --- contain_dom -----------------------------------------------------

  def test_contain_dom_matches_existing_selector
    m = contain_dom("button.primary")
    assert(m.matches?(@dom))
  end

  def test_contain_dom_does_not_match_missing_selector
    m = contain_dom("button.danger")
    refute(m.matches?(@dom))
  end

  def test_contain_dom_with_text_filter
    m = contain_dom("h1", text: "Hello")
    assert(m.matches?(@dom))

    m = contain_dom("h1", text: "Goodbye")
    refute(m.matches?(@dom))
  end

  def test_contain_dom_with_text_regexp
    m = contain_dom("h1", text: /^Hell/)
    assert(m.matches?(@dom))
  end

  def test_contain_dom_with_exact_count
    m = contain_dom("li", count: 3)
    assert(m.matches?(@dom))

    m = contain_dom("li", count: 5)
    refute(m.matches?(@dom))
  end

  def test_contain_dom_with_range_count
    m = contain_dom("li", count: 1..5)
    assert(m.matches?(@dom))

    m = contain_dom("li", count: 5..10)
    refute(m.matches?(@dom))
  end

  def test_contain_dom_failure_message_mentions_actual_count
    m = contain_dom("li", count: 5)
    m.matches?(@dom)
    assert_match(/found 3/, m.failure_message)
  end

  # --- contain_dom_text -----------------------------------------------

  def test_contain_dom_text_string
    m = contain_dom_text("Submit")
    assert(m.matches?(@dom))
  end

  def test_contain_dom_text_regexp
    m = contain_dom_text(/Sub.*it/)
    assert(m.matches?(@dom))
  end

  def test_contain_dom_text_misses
    m = contain_dom_text("Cancel")
    refute(m.matches?(@dom))
  end

  # --- have_dom_attribute ---------------------------------------------

  def test_have_dom_attribute_existence
    m = have_dom_attribute("disabled")
    assert(m.matches?(@button))
  end

  def test_have_dom_attribute_with_value
    m = have_dom_attribute("type", "submit")
    assert(m.matches?(@button))
  end

  def test_have_dom_attribute_wrong_value
    m = have_dom_attribute("type", "reset")
    refute(m.matches?(@button))
  end

  def test_have_dom_attribute_missing
    m = have_dom_attribute("name")
    refute(m.matches?(@button))
  end

  # --- have_dom_class -------------------------------------------------

  def test_have_dom_class_present
    m = have_dom_class("primary")
    assert(m.matches?(@button))
  end

  def test_have_dom_class_missing
    m = have_dom_class("danger")
    refute(m.matches?(@button))
  end

  def test_have_dom_class_multiple
    m = have_dom_class("featured")
    assert(m.matches?(@article))
  end

  # --- match_dom_html -------------------------------------------------

  def test_match_dom_html_ignores_whitespace
    el = @dom.query_selector("h1")
    m = match_dom_html("Hello")
    assert(m.matches?(el))
  end

  def test_match_dom_html_detects_diff
    el = @dom.query_selector("h1")
    m = match_dom_html("Goodbye")
    refute(m.matches?(el))
  end
end
