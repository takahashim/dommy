require "test_helper"

class TestStimulus < Minitest::Test
  include Dommy::TestHelpers

  def test_has_controller
    html = '<div data-controller="dropdown"></div>'
    doc = parse_html(html)
    el = doc.query_selector("div")
    assert Dommy::Rails::Stimulus.has_controller?(el, "dropdown")
    refute Dommy::Rails::Stimulus.has_controller?(el, "modal")
  end

  def test_has_action
    html = '<button data-action="click->dropdown#toggle"></button>'
    doc = parse_html(html)
    el = doc.query_selector("button")
    assert Dommy::Rails::Stimulus.has_action?(el, "click->dropdown#toggle")
  end

  def test_has_target
    html = '<div data-dropdown-target="menu"></div>'
    doc = parse_html(html)
    el = doc.query_selector("div")
    assert Dommy::Rails::Stimulus.has_target?(el, "dropdown", "menu")
    refute Dommy::Rails::Stimulus.has_target?(el, "dropdown", "button")
  end

  def test_has_value
    html = '<div data-dropdown-open-value="false"></div>'
    doc = parse_html(html)
    el = doc.query_selector("div")
    assert Dommy::Rails::Stimulus.has_value?(el, "dropdown", "open", "false")
    refute Dommy::Rails::Stimulus.has_value?(el, "dropdown", "open", "true")
  end
end
