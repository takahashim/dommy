# frozen_string_literal: true

require_relative "test_helper"

# Dommy::Backend is what the DOM asks of Makiri, in one place.
class TestBackend < Minitest::Test
  def test_parse_gives_a_makiri_document
    doc = Dommy::Backend.parse("<div>hello</div>")
    assert_kind_of(Makiri::HTML::Document, doc)
    assert(doc.at_css("div"))
  end

  # The by-qualified-name lookups under getAttribute / setAttribute /
  # removeAttribute: the node and the value spellings have to agree.
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
