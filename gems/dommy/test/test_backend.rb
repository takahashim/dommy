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
    # Makiri adapter is acceptable
    assert(Dommy::Backend.current.respond_to?(:parse))
  end

  def test_use_makiri_explicitly
    Dommy::Backend.use(:makiri)
    assert_equal(Dommy::Backend::Makiri, Dommy::Backend.current)
  end

  def test_unknown_backend_raises
    assert_raises(ArgumentError) { Dommy::Backend.use(:webkit) }
  end

  def test_parse_works_with_makiri
    Dommy::Backend.use(:makiri)
    doc = Dommy::Backend.parse("<div>hello</div>")
    refute_nil(doc)
    assert(doc.at_css("div"))
  end

  def test_dommy_accessor_aliases_backend
    Dommy::Backend.use(:makiri)
    assert_equal(Dommy::Backend::Makiri, Dommy.backend)
  end

  # The by-qualified-name lookups under getAttribute / setAttribute /
  # removeAttribute. The adapter answers them natively when the backend can and
  # scans in Ruby when it cannot; both spellings have to agree, so these run
  # against whichever is in use.
  class TestAttributeByQualifiedName < Minitest::Test
    XML_NS = "http://www.w3.org/XML/1998/namespace"

    def setup
      @doc = Dommy.parse("<div id='d'>x</div>").document
      @node = @doc.query_selector("div").__dommy_backend_node__
      Dommy::Backend.set_attribute_ns(@node, XML_NS, "xml", "b", "xml:b", "vv")
    end

    def value(name)
      Dommy::Backend.attr_value_by_qualified_name(@node, name)
    end

    def node_for(name)
      Dommy::Backend.attr_by_qualified_name(@node, name)
    end

    def test_the_qualified_name_matches_and_the_local_name_does_not
      assert_equal "vv", value("xml:b")
      assert_nil value("b")
      assert_equal "d", value("id")
    end

    def test_the_node_and_the_value_lookups_agree
      assert_equal "vv", node_for("xml:b").value
      assert_nil node_for("b")
      assert_equal XML_NS, Dommy::Backend.attribute_ns_info(node_for("xml:b"))[:namespace_uri]
    end

    def test_an_absent_attribute_is_nil_and_an_empty_one_is_not
      assert_nil value("nope")
      assert_nil node_for("nope")
      Dommy::Backend.set_attribute_ns(@node, nil, nil, "empty", "empty", "")
      assert_equal "", value("empty")
    end
  end
end
