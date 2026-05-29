# frozen_string_literal: true

require_relative "test_helper"

class TestBackend < Minitest::Test
  def teardown
    # Reset backend to default after each test.
    Dommy::Backend.current = nil
    Dommy::Backend.send(:detect_default)
  rescue StandardError
    nil
  end

  def test_default_backend_loaded
    refute_nil(Dommy::Backend.current)
    # Either Nokogiri or Nokolexbor adapter is acceptable
    assert(Dommy::Backend.current.respond_to?(:parse))
  end

  def test_use_nokogiri_explicitly
    Dommy::Backend.use(:nokogiri)
    assert_equal(Dommy::Backend::Nokogiri, Dommy::Backend.current)
  end

  def test_use_nokolexbor_explicitly
    Dommy::Backend.use(:nokolexbor)
    assert_equal(Dommy::Backend::Nokolexbor, Dommy::Backend.current)
  end

  def test_unknown_backend_raises
    assert_raises(ArgumentError) { Dommy::Backend.use(:webkit) }
  end

  def test_parse_works_with_nokogiri
    Dommy::Backend.use(:nokogiri)
    doc = Dommy::Backend.parse("<div>hello</div>")
    refute_nil(doc)
    assert(doc.at_css("div"))
  end

  def test_parse_works_with_nokolexbor
    Dommy::Backend.use(:nokolexbor)
    doc = Dommy::Backend.parse("<div>hello</div>")
    refute_nil(doc)
    assert(doc.at_css("div"))
  end

  def test_dommy_accessor_aliases_backend
    Dommy::Backend.use(:nokogiri)
    assert_equal(Dommy::Backend::Nokogiri, Dommy.backend)
  end
end
