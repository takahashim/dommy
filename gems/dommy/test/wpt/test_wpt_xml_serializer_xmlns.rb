# frozen_string_literal: true

require_relative "../test_helper"

# An XML serialization reconciles the element's `xmlns` declaration with the
# namespace the element is actually in, and drops the declaration when the two
# disagree. The declaration is found by its LOCAL NAME: `setAttribute("xmlns",
# …)` creates a null-namespace attribute — only `setAttributeNS` puts one in the
# XMLNS namespace — and it counts all the same.
#
# WPT: domparsing/XMLSerializer-serializeToString.html
#      ("Drop inconsistent xmlns=... by matching on local name")
# Spec: https://w3c.github.io/DOM-Parsing/#xml-serializing-an-element-node
class TestWPTXMLSerializerXmlns < Minitest::Test
  OPF = "http://www.idpf.org/2007/opf"
  XMLNS_NS = "http://www.w3.org/2000/xmlns/"

  def setup
    @parser = Dommy::DOMParser.new
    @serializer = Dommy::XMLSerializer.new
  end

  def parse(xml)
    @parser.parse_from_string(xml, "application/xml").document_element
  end

  def serialize(node)
    @serializer.serialize_to_string(node)
  end

  # setAttribute leaves the attribute in NO namespace, which is what makes the
  # local-name match necessary.
  def test_set_attribute_xmlns_stays_in_no_namespace
    root = parse("<package></package>")
    root.set_attribute("xmlns", OPF)
    attr = root.attributes.to_a.find { |a| a.local_name == "xmlns" }
    assert_nil attr.namespace_uri
    assert_nil attr.prefix
  end

  def test_a_declaration_contradicting_an_element_in_no_namespace_is_dropped
    root = parse("<package></package>")
    root.set_attribute("xmlns", OPF)
    manifest = root.append_child(root.owner_document.create_element("manifest"))
    manifest.set_attribute("xmlns", OPF)
    assert_equal "<package><manifest/></package>", serialize(root)
  end

  def test_a_child_in_no_namespace_resets_the_inherited_default_once
    root = parse(%(<package xmlns="#{OPF}"></package>))
    manifest = root.append_child(root.owner_document.create_element("manifest"))
    manifest.set_attribute("xmlns", OPF)
    assert_equal %(<package xmlns="#{OPF}"><manifest xmlns=""/></package>), serialize(root)
  end

  def test_a_child_in_no_namespace_resets_it_without_any_declaration_of_its_own
    root = parse(%(<package xmlns="#{OPF}"></package>))
    root.append_child(root.owner_document.create_element("manifest"))
    assert_equal %(<package xmlns="#{OPF}"><manifest xmlns=""/></package>), serialize(root)
  end

  # A declaration that AGREES with the element's namespace is the element's own
  # `xmlns` and is written out; it must not be dropped along with the
  # contradicting ones.
  def test_a_declaration_matching_the_element_namespace_is_kept
    doc = @parser.parse_from_string("<r/>", "application/xml")
    el = doc.create_element_ns(OPF, "package")
    el.set_attribute("xmlns", OPF)
    assert_equal %(<package xmlns="#{OPF}"/>), serialize(el)
  end

  # The same attribute created through setAttributeNS — in the XMLNS namespace —
  # behaves identically.
  def test_the_namespaced_spelling_behaves_the_same
    root = parse("<package></package>")
    root.set_attribute_ns(XMLNS_NS, "xmlns", OPF)
    assert_equal "<package/>", serialize(root)
  end
end
