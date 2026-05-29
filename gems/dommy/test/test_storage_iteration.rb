# frozen_string_literal: true

require_relative "test_helper"

class TestStorageIteration < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @storage = @win.__js_get__("localStorage")
    @storage.set_item("a", "1")
    @storage.set_item("b", "2")
    @storage.set_item("c", "3")
  end

  def test_keys
    assert_equal(["a", "b", "c"], @storage.keys)
  end

  def test_values
    assert_equal(["1", "2", "3"], @storage.values)
  end

  def test_entries
    assert_equal([["a", "1"], ["b", "2"], ["c", "3"]], @storage.entries)
  end

  def test_to_h
    assert_equal({"a" => "1", "b" => "2", "c" => "3"}, @storage.to_h)
  end

  def test_each_yields_pairs
    pairs = []
    @storage.each { |k, v| pairs << [k, v] }
    assert_equal([["a", "1"], ["b", "2"], ["c", "3"]], pairs)
  end

  def test_index_accessor
    assert_equal("2", @storage["b"])
    @storage["d"] = "4"
    assert_equal("4", @storage["d"])
  end

  def test_size_alias
    assert_equal(3, @storage.size)
    assert_equal(3, @storage.length)
  end
end
