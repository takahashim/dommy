# frozen_string_literal: true

require_relative "test_helper"

class TestDataset < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x' data-role='primary' data-user-id='42'></div>")
    @el = @win.document.get_element_by_id("x")
    @ds = @el.dataset
  end

  def test_read_simple_key
    assert_equal("primary", @ds.__js_get__("role"))
  end

  def test_read_camelcase_maps_to_kebab_attribute
    assert_equal("42", @ds.__js_get__("userId"))
  end

  def test_missing_returns_nil
    assert_nil(@ds.__js_get__("missing"))
  end

  def test_set_writes_attribute_with_kebab
    @ds.__js_set__("status", "active")
    assert_equal("active", @el.get_attribute("data-status"))
  end

  def test_set_camelcase_kebabs_at_attribute_level
    @ds.__js_set__("itemCount", "7")
    assert_equal("7", @el.get_attribute("data-item-count"))
  end
end
