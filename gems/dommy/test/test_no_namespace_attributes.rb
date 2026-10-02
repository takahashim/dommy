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

  # The JS side answers `el.id` from its attribute snapshot, so an element
  # with an unprefixed namespaced attribute is not snapshotted.
  def test_snapshot
    el = element
    el.set_attribute("id", "plain")
    refute_nil(el.__js_attribute_snapshot__)
    el.set_attribute_ns(NS, "title", "ns")
    assert_nil(el.__js_attribute_snapshot__)
  end
end
