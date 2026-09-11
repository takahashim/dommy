# frozen_string_literal: true

require_relative "../test_helper"

# "queue a mutation record" step 2.3 tests each registration of an observer on
# its own: the scope, the record type, and — for "attributes" — the
# attributeFilter are one condition, and step 2.3.3 lets ANY matching
# registration turn on the old value. One observer with two registrations is
# where the difference shows.
#
# Spec: https://dom.spec.whatwg.org/#queueing-a-mutation-record
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTMutationObserverAttributeOptions < Minitest::Test
  include DommyTestHelper

  XML_NS = "http://www.w3.org/XML/1998/namespace"

  def setup
    @win = make_window
    @doc = @win.document
    @parent = @doc.create_element("div")
    @child = @doc.create_element("span")
    @parent.append_child(@child)
    @doc.body.append_child(@parent)
    @records = []
    @observer = Dommy::MutationObserver.new(@win, proc { |rs| @records.concat(rs) })
  end

  def observe(target, options)
    @observer.__js_call__("observe", [target, options])
  end

  def taken
    @observer.__js_call__("takeRecords", []).to_a
  end

  # A registration whose attributeFilter excludes this attribute must not hide
  # another registration of the same observer that accepts it.
  def test_a_filtered_registration_does_not_shadow_an_unfiltered_one
    observe(@child, { "attributes" => true, "attributeFilter" => ["a"] })
    observe(@parent, { "attributes" => true, "subtree" => true })

    @child.set_attribute("b", "1")

    records = taken
    assert_equal 1, records.size
    assert_equal "b", records.first.__js_get__("attributeName")
  end

  # Symmetrically, the filter still excludes the attribute when it is the only
  # registration that could match.
  def test_a_filter_that_excludes_the_attribute_queues_nothing
    observe(@child, { "attributes" => true, "attributeFilter" => ["a"] })

    @child.set_attribute("b", "1")

    assert_empty taken
  end

  # attributeFilter matches on the local name of a NULL-namespace attribute; a
  # namespaced attribute is never in a filter's scope.
  def test_a_filter_never_matches_a_namespaced_attribute
    observe(@child, { "attributes" => true, "attributeFilter" => ["b"] })

    @child.set_attribute_ns(XML_NS, "xml:b", "1")

    assert_empty taken
  end

  # step 2.3.3: the old value is recorded when ANY matching registration asks
  # for it, not only when the first one reached does.
  def test_old_value_comes_from_any_matching_registration
    text = @doc.create_text_node("t5")
    @child.append_child(text)
    observe(text, { "characterData" => true, "characterDataOldValue" => false })
    observe(@parent, { "characterData" => true, "characterDataOldValue" => true,
                       "subtree" => true })

    text.append_data("yz")

    records = taken
    assert_equal 1, records.size
    assert_equal "t5", records.first.__js_get__("oldValue")
  end

  def test_attribute_old_value_comes_from_any_matching_registration
    @child.set_attribute("a", "old")
    observe(@child, { "attributes" => true })
    observe(@parent, { "attributes" => true, "attributeOldValue" => true, "subtree" => true })

    @child.set_attribute("a", "new")

    records = taken
    assert_equal 1, records.size
    assert_equal "old", records.first.__js_get__("oldValue")
  end
end
