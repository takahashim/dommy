# frozen_string_literal: true

require_relative "test_helper"

# :nth-child and :nth-of-type list a parent's children once per match, not
# once per sibling asked about, and a match that lives through a change of
# the tree — the cascade's lives through a style pass — lists them again.
class TestNthChildPositions < Minitest::Test
  def setup
    @doc = Dommy.parse("<ul id=t><li>a</li><li>b</li><li>c</li></ul>").document
    @ul = @doc.get_element_by_id("t")
  end

  def ast(selector) = Dommy::Internal::SelectorParser.parse!(selector)

  def test_a_kept_match_follows_a_change_of_the_tree
    match = Dommy::Internal::SelectorMatcher::Match.for(@doc, nil)
    second = ast("li:nth-child(2)")
    b = @ul.children[1]
    assert match.list?(b, second)

    @ul.insert_before(@doc.create_element("li"), @ul.first_child)
    refute match.list?(b, second)
    assert match.list?(@ul.children[1], second)
  end

  # The type is the namespace and local name: an `li` in another namespace
  # is the first of its own type, and not counted among the HTML ones.
  def test_nth_of_type_counts_the_elements_of_the_same_namespace
    foreign = @doc.create_element_ns("urn:x", "li")
    foreign.text_content = "x"
    @ul.insert_before(foreign, @ul.first_child)
    assert_equal %w[x a c], @doc.query_selector_all("li:nth-of-type(odd)").map(&:text_content)
    assert_equal %w[x c], @doc.query_selector_all("li:nth-last-of-type(1)").map(&:text_content)
  end
end
