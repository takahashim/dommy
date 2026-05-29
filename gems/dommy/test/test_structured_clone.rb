# frozen_string_literal: true

require_relative "test_helper"

class TestStructuredClone < Minitest::Test
  include DommyTestHelper

  def test_primitives_pass_through
    assert_equal(42, Dommy.structured_clone(42))
    assert_equal(3.14, Dommy.structured_clone(3.14))
    assert_equal(true, Dommy.structured_clone(true))
    assert_nil(Dommy.structured_clone(nil))
  end

  def test_string_is_copied_not_shared
    s = "hello"
    c = Dommy.structured_clone(s)
    assert_equal(s, c)
    refute_same(s, c)
  end

  def test_array_deep_clone
    src = [1, [2, 3], {"k" => "v"}]
    c = Dommy.structured_clone(src)
    assert_equal(src, c)
    refute_same(src, c)
    refute_same(src[1], c[1])
    refute_same(src[2], c[2])
  end

  def test_hash_deep_clone
    src = {"a" => {"b" => 1}}
    c = Dommy.structured_clone(src)
    assert_equal(src, c)
    refute_same(src["a"], c["a"])
  end

  def test_cyclic_array
    a = []
    a << a
    c = Dommy.structured_clone(a)
    assert_same(c, c[0])
  end

  def test_cyclic_hash
    h = {}
    h["self"] = h
    c = Dommy.structured_clone(h)
    assert_same(c, c["self"])
  end

  def test_symbol_passes_through_unchanged
    assert_equal(:foo, Dommy.structured_clone(:foo))
  end

  def test_function_raises_DataCloneError
    assert_raises(Dommy::DOMException::DataCloneError) { Dommy.structured_clone(-> { }) }
  end

  def test_class_raises_DataCloneError
    assert_raises(Dommy::DOMException::DataCloneError) { Dommy.structured_clone(String) }
  end

  def test_io_raises_DataCloneError
    assert_raises(Dommy::DOMException::DataCloneError) { Dommy.structured_clone(STDOUT) }
  end

  def test_clones_dom_node_via_cloneNode
    win = make_window
    doc = win.document
    div = doc.create_element("div")
    div.set_attribute("id", "x")
    div.append_child(doc.create_element("p"))

    c = Dommy.structured_clone(div)
    refute_same(div, c)
    assert_equal("x", c.id)
    assert_equal(1, c.child_element_count)
  end

  def test_javascript_alias
    assert_equal([1, 2], Dommy.structuredClone([1, 2]))
  end

  def test_time_dup
    t = Time.now
    c = Dommy.structured_clone(t)
    assert_equal(t, c)
    refute_same(t, c)
  end

  def test_regexp_dup
    r = /abc/
    c = Dommy.structured_clone(r)
    assert_equal(r, c)
    refute_same(r, c)
  end

  def test_set_deep_clone
    s = Set[1, 2, 3]
    c = Dommy.structured_clone(s)
    assert_equal(s, c)
    refute_same(s, c)
  end
end
