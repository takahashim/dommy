# frozen_string_literal: true

require_relative "test_helper"

class TestBackend < Minitest::Test
  def teardown
    # Restore the backend the suite is running against (the DOMMY_BACKEND
    # override, or the auto-detected default) after each test.
    if (backend = ENV["DOMMY_BACKEND"])
      Dommy::Backend.use(backend.to_sym)
    else
      Dommy::Backend.current = nil
      Dommy::Backend.send(:detect_default)
    end
  rescue StandardError
    nil
  end

  def test_default_backend_loaded
    refute_nil(Dommy::Backend.current)
    # Either Nokogiri or Makiri adapter is acceptable
    assert(Dommy::Backend.current.respond_to?(:parse))
  end

  def test_use_nokogiri_explicitly
    Dommy::Backend.use(:nokogiri)
    assert_equal(Dommy::Backend::Nokogiri, Dommy::Backend.current)
  end

  def test_use_makiri_explicitly
    Dommy::Backend.use(:makiri)
    assert_equal(Dommy::Backend::Makiri, Dommy::Backend.current)
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

  def test_parse_works_with_makiri
    Dommy::Backend.use(:makiri)
    doc = Dommy::Backend.parse("<div>hello</div>")
    refute_nil(doc)
    assert(doc.at_css("div"))
  end

  def test_dommy_accessor_aliases_backend
    Dommy::Backend.use(:nokogiri)
    assert_equal(Dommy::Backend::Nokogiri, Dommy.backend)
  end
end
