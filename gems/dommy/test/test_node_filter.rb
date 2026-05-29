# frozen_string_literal: true

require_relative "test_helper"

class TestNodeFilter < Minitest::Test
  def test_show_constants
    assert_equal(0x1, Dommy::NodeFilter::SHOW_ELEMENT)
    assert_equal(0x2, Dommy::NodeFilter::SHOW_ATTRIBUTE)
    assert_equal(0x4, Dommy::NodeFilter::SHOW_TEXT)
    assert_equal(0x8, Dommy::NodeFilter::SHOW_CDATA_SECTION)
    assert_equal(0x80, Dommy::NodeFilter::SHOW_COMMENT)
    assert_equal(0x100, Dommy::NodeFilter::SHOW_DOCUMENT)
    assert_equal(0x200, Dommy::NodeFilter::SHOW_DOCUMENT_TYPE)
    assert_equal(0x400, Dommy::NodeFilter::SHOW_DOCUMENT_FRAGMENT)
    assert_equal(0xFFFFFFFF, Dommy::NodeFilter::SHOW_ALL)
  end

  def test_filter_result_constants
    assert_equal(1, Dommy::NodeFilter::FILTER_ACCEPT)
    assert_equal(2, Dommy::NodeFilter::FILTER_REJECT)
    assert_equal(3, Dommy::NodeFilter::FILTER_SKIP)
  end
end
