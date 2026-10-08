# frozen_string_literal: true

require_relative "test_helper"
require "dommy/js/constructor_resolver"

# The static method names of an interface constructor are what the JS side
# attaches to each seeded global (URL.parse, …). Every window load asks for
# all of them, so they are worked out once per process.
class TestConstructorResolver < Minitest::Test
  def setup
    @resolver = Dommy::Js::ConstructorResolver.new
    @resolver.source = Dommy.parse("<p>x</p>")
  end

  def test_static_names_lists_an_interfaces_class_methods
    assert_equal %w[createObjectURL revokeObjectURL parse canParse].sort, @resolver.static_names("URL").sort
    assert_empty @resolver.static_names("Node")
  end

  def test_static_names_are_shared_across_windows
    other = Dommy::Js::ConstructorResolver.new
    other.source = Dommy.parse("<p>y</p>")
    assert_same @resolver.static_names("URL"), other.static_names("URL")
    assert_predicate @resolver.static_names("URL"), :frozen?
  end
end
