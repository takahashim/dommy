# frozen_string_literal: true

require_relative "test_helper"

# A document parsed as HTML and typed as XHTML or XML afterwards — what
# dommy-rack does with such a response — makes elements as that type's
# createElement does: the name's case kept, in the HTML namespace for XHTML
# and in none for XML.
class TestCreateElementTypedDocument < Minitest::Test
  def element(content_type, name)
    doc = Dommy.parse("<p>x</p>").document
    doc.content_type = content_type
    el = doc.create_element(name)
    [el.local_name, el.tag_name, el.namespace_uri]
  end

  def test_an_xhtml_typed_document_keeps_the_case
    assert_equal %w[fooBar fooBar http://www.w3.org/1999/xhtml], element("application/xhtml+xml", "fooBar")
  end

  def test_an_xml_typed_document_puts_it_in_no_namespace
    assert_equal ["fooBar", "fooBar", nil], element("application/xml", "fooBar")
  end

  def test_an_html_document_lowercases_it
    assert_equal %w[foobar FOOBAR http://www.w3.org/1999/xhtml], element("text/html", "fooBar")
  end

  # createElement takes `xmlns` as a local name like any other, though
  # createElementNS would refuse it outside the XMLNS namespace.
  def test_an_element_named_xmlns_is_an_html_element
    assert_equal %w[xmlns XMLNS http://www.w3.org/1999/xhtml], element("text/html", "xmlns")
  end
end

