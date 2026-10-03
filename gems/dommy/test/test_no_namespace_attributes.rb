# frozen_string_literal: true

require_relative "test_helper"

# HTML reads and writes its content attributes in no namespace (§2.6.1): an
# attribute with the same name in another namespace — made only by
# setAttributeNS — is no reflected attribute, no data-* entry and no style.
class TestNoNamespaceAttributes < Minitest::Test
  include DommyTestHelper

  NS = "urn:x"

  def setup
    @doc = make_window("<div id=host></div>").document
    @host = @doc.get_element_by_id("host")
  end

  def element(tag = "div")
    @host.append_child(@doc.create_element(tag))
  end

  def attrs(el)
    el.attributes.map { |a| [a.namespace_uri, a.value] }
  end

  def test_id_class_name_and_slot
    el = element
    %w[id class slot].each { |name| el.set_attribute_ns(NS, name, "ns") }
    assert_equal(["", "", ""], %w[id className slot].map { |k| el.__js_get__(k) })

    el.__js_set__("id", "i")
    el.__js_set__("className", "c")
    el.__js_set__("slot", "s")
    assert_equal(["i", "c", "s"], %w[id className slot].map { |k| el.__js_get__(k) })
    assert_equal(["ns", "ns", "ns"], %w[id class slot].map { |name| el.get_attribute_ns(NS, name) })
  end

  def test_reflected_attributes
    link = element("link")
    link.set_attribute_ns(NS, "disabled", "")
    link.set_attribute_ns(NS, "rel", "ns")
    link.set_attribute_ns(NS, "href", "/ns")
    assert_equal([false, "", ""], %w[disabled rel href].map { |k| link.__js_get__(k) })

    link.__js_set__("rel", "icon")
    link.__js_set__("disabled", true)
    assert_equal(["icon", true], %w[rel disabled].map { |k| link.__js_get__(k) })
    link.__js_set__("disabled", false)
    assert_equal([[NS, ""], [NS, "ns"], [NS, "/ns"], [nil, "icon"]], attrs(link))

    ol = element("ol")
    ol.set_attribute_ns(NS, "start", "5")
    assert_equal(1, ol.__js_get__("start"))
  end

  # A camel-cased IDL name reflects its lowercase content attribute.
  def test_a_camel_cased_reflection_names_its_attribute_in_lowercase
    form = element("form")
    form.__js_set__("noValidate", true)
    assert_equal(["novalidate"], form.attributes.map(&:name))
  end

  def test_hidden_and_dir
    el = element
    el.set_attribute_ns(NS, "hidden", "")
    el.set_attribute_ns(NS, "dir", "rtl")
    assert_equal([false, ""], %w[hidden dir].map { |k| el.__js_get__(k) })

    el.__js_set__("hidden", true)
    el.__js_set__("hidden", false)
    assert_equal("", el.get_attribute_ns(NS, "hidden"))
  end

  def test_dataset
    el = element
    el.set_attribute_ns(NS, "data-a", "ns")
    assert_equal([], el.dataset.__js_named_props__)
    assert_equal(Dommy::Bridge::ABSENT, el.dataset.__js_get__("a"))

    el.dataset.__js_set__("a", "plain")
    assert_equal([[NS, "ns"], [nil, "plain"]], attrs(el))
    el.dataset.__js_delete__("a")
    assert_equal([[NS, "ns"]], attrs(el))
  end

  def test_style
    el = element
    el.set_attribute_ns(NS, "style", "color: red")
    assert_equal("", el.style.get_property_value("color"))
    assert_nil(Dommy::Internal::CSS::Cascade.computed_style(el)["color"]&.then { |c| c == "red" ? c : nil })

    el.style.set_property("color", "blue")
    assert_equal([[NS, "color: red"], [nil, "color: blue;"]], attrs(el))
  end

  def test_collection_named_items
    p = element("p")
    p.set_attribute_ns(NS, "id", "i")
    p.set_attribute_ns(NS, "name", "n")
    assert_nil(@host.children.named_item("i"))
    assert_nil(@host.children.named_item("n"))
    assert_equal([], @host.children.__js_named_props__)
  end

  # :lang reads `xml:lang` first, then `lang` in no namespace on an HTML,
  # SVG or MathML element; an empty value is an unknown language, which
  # stops the search.
  def test_lang
    outer = element
    outer.set_attribute("lang", "fr")
    inner = outer.append_child(@doc.create_element("p"))
    inner.set_attribute_ns(NS, "lang", "de")
    assert(inner.matches?(":lang(fr)"))

    inner.set_attribute_ns("http://www.w3.org/XML/1998/namespace", "xml:lang", "de")
    assert(inner.matches?(":lang(de)"))

    inner.remove_attribute_ns("http://www.w3.org/XML/1998/namespace", "lang")
    inner.set_attribute_ns(nil, "lang", "")
    refute(inner.matches?(":lang(fr)"))
  end

  # The JS side answers `el.id` from its attribute snapshot, so an element
  # with an unprefixed namespaced attribute is not snapshotted.
  def test_snapshot
    el = element
    el.set_attribute("id", "plain")
    refute_nil(el.__js_attribute_snapshot__)
    el.set_attribute_ns(NS, "title", "ns")
    assert_nil(el.__js_attribute_snapshot__)
  end

  # HTML's own algorithms read the attributes in no namespace too: one in
  # another namespace makes nothing required, a link, a named property of
  # the document or a checkbox's submitted value.
  def test_html_algorithms
    input = element("input")
    input.set_attribute_ns(NS, "required", "")
    a = element("a")
    a.set_attribute_ns(NS, "href", "/")
    img = element("img")
    img.set_attribute_ns(NS, "name", "pic")
    refute input.matches?(":required")
    refute a.matches?(":any-link")
    refute_includes @doc.__js_named_props__, "pic"

    form = element("form")
    box = form.append_child(@doc.create_element("input"))
    box.set_attribute("type", "checkbox")
    box.set_attribute("name", "b")
    box.set_attribute("checked", "")
    box.set_attribute_ns(NS, "value", "ns")
    assert_equal [["b", "on"]], Dommy::FormData.new(form).entries.to_a
  end

  # The getters that read an attribute named by an argument read it in no
  # namespace too.
  def test_attributes_read_by_name
    meter = element("meter")
    meter.set_attribute_ns(NS, "max", "5")
    canvas = element("canvas")
    canvas.set_attribute_ns(NS, "width", "10")
    input = element("input")
    input.set_attribute_ns(NS, "maxlength", "3")
    assert_equal [1.0, 300, -1], [meter.__js_get__("max"), canvas.__js_get__("width"), input.__js_get__("maxLength")]
  end
end
