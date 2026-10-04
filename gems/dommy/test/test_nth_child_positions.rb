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

  # A fragment's and a shadow root's children are siblings as an element's
  # are, for every :nth-* as for :first-child.
  def test_the_children_of_a_fragment_or_a_shadow_root_count_their_places
    fragment = @doc.create_document_fragment
    3.times { |i| fragment.append_child(@doc.create_element("i")).text_content = i.to_s }
    host = @doc.create_element("div")
    shadow = host.attach_shadow("mode" => "open")
    shadow.inner_html = "<i>0</i><b>x</b><i>1</i><i>2</i>"

    [fragment, shadow].each do |root|
      assert_equal %w[1], root.query_selector_all("i:nth-of-type(2)").map(&:text_content)
      assert_equal %w[2], root.query_selector_all("i:nth-last-child(1)").map(&:text_content)
      assert_equal %w[0], root.query_selector_all(":first-child").map(&:text_content)
    end
    assert_equal %w[1], fragment.query_selector_all("i:nth-child(2)").map(&:text_content)
    assert_equal %w[1], shadow.query_selector_all(":nth-child(2 of i)").map(&:text_content)
  end
end

