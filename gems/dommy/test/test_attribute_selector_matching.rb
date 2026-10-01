# frozen_string_literal: true

require_relative "test_helper"

# Attribute selectors (Selectors 4 §6.3, §6.4) name a LOCAL name and a
# namespace condition, and match when ANY attribute meeting both passes the
# value test. The value test folds case only within ASCII, and `~=` splits on
# ASCII whitespace.
class TestAttributeSelectorMatching < Minitest::Test
  include DommyTestHelper

  NS = "http://example.com/ns"

  def setup
    @doc = make_window("<div id=root></div>").document
    @root = @doc.get_element_by_id("root")
  end

  def element(*attrs)
    e = @doc.create_element("p")
    # setAttributeNS even for no namespace: setAttribute would find a
    # namespaced `a` by its qualified name and overwrite it.
    attrs.each { |namespace, qualified_name, value| e.set_attribute_ns(namespace, qualified_name, value) }
    @root.append_child(e)
    e
  end

  def matching(selector) = @root.query_selector_all(selector).to_a

  def test_any_namespace_looks_at_every_attribute_with_the_local_name
    plain_first = element([nil, "a", "1"], [NS, "x:a", "2"])
    namespaced_first = element([NS, "x:a", "1"], [nil, "a", "2"])

    assert_equal [plain_first, namespaced_first], matching("[*|a='2']")
    assert_equal [plain_first, namespaced_first], matching("[*|a='1']")
    assert_equal [plain_first, namespaced_first], matching("[*|a^='2']")
  end

  def test_no_namespace_ignores_a_namespaced_attribute_of_the_same_local_name
    e = element([NS, "a", "2"], [nil, "a", "1"])

    assert_empty matching("[a='2']")
    assert_equal [e], matching("[a='1']")
    assert_equal [e], matching("[|a='1']")

    element([NS, "a", "3"])
    assert_equal [e], matching("[a]"), "a namespaced `a` alone is no `a` in no namespace"
  end

  def test_the_i_flag_folds_case_within_ascii_only
    ascii = element([nil, "c", "K"])
    element([nil, "c", "\u00E4"])

    assert_equal [ascii], matching("[c='k' i]")
    assert_empty matching("[c='\u212A' i]") # KELVIN SIGN
    assert_empty matching("[c='\u00C4' i]")
  end

  def test_includes_splits_on_ascii_whitespace_only
    e = element([nil, "b", "x\vy z"])

    assert_empty matching("[b~=y]")
    assert_equal [e], matching("[b~=z]")
    assert_equal [e], matching("[b~='x\vy']")
  end
end
