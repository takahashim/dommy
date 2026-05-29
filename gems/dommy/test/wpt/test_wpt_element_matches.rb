# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Element.matches() and Element.toggleAttribute().
# Both are implemented in lib/dommy/element.rb but lacked WPT-flavoured
# coverage.
#
# WPT: dom/nodes/Element-matches.html,
#      dom/nodes/Element-toggleAttribute.html
# Spec: https://dom.spec.whatwg.org/#dom-element-matches,
#       https://dom.spec.whatwg.org/#dom-element-toggleattribute
class TestWPTElementMatches < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='target' class='foo bar' data-x='1'></div>")
    @el = @win.document.get_element_by_id("target")
  end

  def test_matches_tag_selector
    assert(@el.matches?("div"))
  end

  def test_matches_class_selector
    assert(@el.matches?(".foo"))
  end

  def test_matches_id_selector
    assert(@el.matches?("#target"))
  end

  def test_matches_attribute_selector
    assert(@el.matches?("[data-x]"))
    assert(@el.matches?("[data-x='1']"))
  end

  def test_matches_compound_selector
    assert(@el.matches?("div.foo#target"))
  end

  def test_matches_returns_false_for_non_matching_tag
    refute(@el.matches?("span"))
  end

  def test_matches_returns_false_for_missing_class
    refute(@el.matches?(".missing"))
  end
end

class TestWPTElementToggleAttribute < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @el = @win.document.create_element("div")
    @win.document.body.append_child(@el)
  end

  # Spec: toggleAttribute(name) -> true if added, false if removed.
  # No-arg form is the "toggle" semantic.

  def test_toggle_attribute_adds_when_absent
    result = @el.toggle_attribute("hidden")
    assert_equal(true, result)
    assert(@el.has_attribute?("hidden"))
  end

  def test_toggle_attribute_removes_when_present
    @el.toggle_attribute("hidden") # add
    result = @el.toggle_attribute("hidden") # remove
    assert_equal(false, result)
    refute(@el.has_attribute?("hidden"))
  end

  # Spec: toggleAttribute(name, force=true) ensures the attribute is
  # set; toggleAttribute(name, force=false) ensures it is removed.

  def test_toggle_attribute_force_true_adds_when_absent
    result = @el.toggle_attribute("hidden", true)
    assert_equal(true, result)
    assert(@el.has_attribute?("hidden"))
  end

  def test_toggle_attribute_force_true_is_idempotent
    @el.toggle_attribute("hidden", true)
    result = @el.toggle_attribute("hidden", true)
    assert_equal(true, result)
    assert(@el.has_attribute?("hidden"))
  end

  def test_toggle_attribute_force_false_removes_when_present
    @el.toggle_attribute("hidden", true)
    result = @el.toggle_attribute("hidden", false)
    assert_equal(false, result)
    refute(@el.has_attribute?("hidden"))
  end

  def test_toggle_attribute_force_false_is_idempotent_when_absent
    result = @el.toggle_attribute("hidden", false)
    assert_equal(false, result)
    refute(@el.has_attribute?("hidden"))
  end

  def test_toggle_attribute_attribute_value_is_empty_string_when_added
    @el.toggle_attribute("data-x")
    # Per spec, added attributes get an empty-string value.
    assert_equal("", @el.get_attribute("data-x"))
  end
end
