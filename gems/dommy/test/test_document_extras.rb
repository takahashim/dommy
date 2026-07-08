# frozen_string_literal: true

require_relative "test_helper"

class TestDocumentExtras < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<header><h1>Title</h1></header><main><p name='msg'>hi</p></main>")
    @doc = @win.document
  end

  def test_head_returns_head_element
    head = @doc.head
    refute_nil(head)
    assert_equal("HEAD", head.tag_name)
  end

  def test_doctype_returns_html_doctype
    dt = @doc.doctype
    refute_nil(dt)
    assert_equal("html", dt.__js_get__("name"))
    assert_equal(10, dt.__js_get__("nodeType"))
  end

  def test_cookie_round_trip
    @doc.cookie = "session=abc"
    @doc.cookie = "theme=dark; Path=/; Expires=Wed"
    assert_equal("session=abc; theme=dark", @doc.cookie)
  end

  def test_cookie_initially_empty
    assert_equal("", @doc.cookie)
  end

  def test_create_element_ns
    el = @doc.create_element_ns("http://www.w3.org/2000/svg", "svg")
    refute_nil(el)
    # SVG (non-HTML namespace) preserves case — tagName is "svg", not "SVG".
    assert_equal("svg", el.tag_name)
  end

  def test_get_elements_by_tag_name
    h1s = @doc.get_elements_by_tag_name("h1")
    assert_equal(1, h1s.size)
    assert_equal("H1", h1s.first.tag_name)
  end

  def test_get_elements_by_tag_name_star
    all = @doc.get_elements_by_tag_name("*")
    assert_operator(all.size, :>=, 4)
  end

  def test_get_elements_by_name
    list = @doc.get_elements_by_name("msg")
    assert_equal(1, list.size)
    assert_equal("P", list.first.tag_name)
  end

  def test_write_appends_to_body
    before = @doc.body.children.size
    @doc.write("<div id='written'>w</div>")
    assert_equal(before + 1, @doc.body.children.size)
    assert_equal("written", @doc.body.children[-1].id)
  end

  def test_open_close_are_noop
    assert_nil(@doc.open)
    assert_nil(@doc.close)
  end

  def test_node_type_constant
    assert_equal(9, @doc.__js_get__("nodeType"))
  end
end

# The document's WebIDL named getter (document.someName → named element).
class TestDocumentNamedGetter < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window(
      "<form name='f1'></form><img name='pic'><iframe name='frame'></iframe>" \
      "<img name='dup'><img name='dup'><img id='byid' name='hasname'>"
    ).document
  end

  def test_single_named_element_returns_the_element
    assert_instance_of Dommy::HTMLFormElement, @doc.__js_get__("f1")
    assert_instance_of Dommy::HTMLImageElement, @doc.__js_get__("pic")
  end

  def test_multiple_named_elements_return_a_collection
    coll = @doc.__js_get__("dup")
    assert_instance_of Dommy::HTMLCollection, coll
    assert_equal 2, coll.length
  end

  def test_img_exposed_by_id_when_it_also_has_a_name
    assert_instance_of Dommy::HTMLImageElement, @doc.__js_get__("byid")
  end

  def test_unknown_name_is_absent
    assert_equal Dommy::Bridge::ABSENT, @doc.__js_get__("nope")
  end

  def test_supported_property_names
    names = @doc.__js_named_props__
    assert_includes names, "f1"
    assert_includes names, "frame"
    assert_includes names, "byid"
    refute_includes names, "nope"
  end
end

# createElementNS with names an XML backend rejects but DOM permits (via
# Makiri's create_loose_dom_element), and error mapping for invalid names.
class TestCreateElementNSLooseNames < Minitest::Test
  include DommyTestHelper

  def xml_doc
    Dommy::DOMParser.new.parse_from_string(
      "<root xmlns='urn:x'/>", "application/xml"
    )
  end

  def test_leading_invalid_char_raises_invalid_character
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      xml_doc.__js_call__("createElementNS", [nil, "}foo"])
    end
  end

  def test_valid_prefixed_name_preserves_case_and_prefix
    el = xml_doc.__js_call__("createElementNS", ["urn:x", "ns:MyTag"])
    assert_equal "MyTag", el.__js_get__("localName")
    assert_equal "ns", el.__js_get__("prefix")
  end
end
