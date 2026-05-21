# frozen_string_literal: true

require_relative "test_helper"

class TestClassQuery < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div class="primary big"></div>
        <div class="primary"></div>
        <div class="secondary"></div>
      HTML
    )
    @doc = @win.document
  end

  def test_get_elements_by_class_name_document
    results = @doc.get_elements_by_class_name("primary")
    assert_equal(2, results.size)
  end

  def test_get_elements_by_class_name_multi_token
    results = @doc.get_elements_by_class_name("primary big")
    assert_equal(1, results.size)
  end

  def test_get_elements_by_class_name_no_match
    results = @doc.get_elements_by_class_name("nope")
    assert_empty(results)
  end

  def test_get_elements_by_class_name_on_element
    container = @doc.create_element("section")
    inner = @doc.create_element("p")
    inner.set_attribute("class", "primary")
    container.append_child(inner)
    @doc.body.append_child(container)

    assert_equal(1, container.get_elements_by_class_name("primary").size)
  end

  def test_matches_with_simple_selector
    div = @doc.query_selector(".primary.big")
    assert(div.matches?(".primary"))
    refute(div.matches?(".secondary"))
  end
end
