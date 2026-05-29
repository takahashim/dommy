# frozen_string_literal: true

require_relative "test_helper"

# Round out Element coverage with ParentNode/ChildNode mixin methods
# (append/prepend/replaceChildren/before/after/replaceWith) and the
# getInnerHTML/getHTML aliases.
class TestElementFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><span id='a'>A</span><span id='b'>B</span></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
  end

  def test_append_appends_nodes
    el = @doc.create_element("em")
    @root.append(el)
    assert_equal("EM", @root.children[-1].tag_name)
  end

  def test_append_accepts_string
    @root.append("trailing")
    assert_match(/trailing/, @root.text_content)
  end

  def test_append_mixed_args
    @root.append("X", @doc.create_element("u"), "Y")
    text = @root.text_content
    assert(text.include?("X"))
    assert(text.include?("Y"))
  end

  def test_prepend_inserts_first
    el = @doc.create_element("em")
    @root.prepend(el)
    assert_equal("EM", @root.children[0].tag_name)
  end

  def test_prepend_with_string_first
    @root.prepend("lead")
    assert(@root.text_content.start_with?("lead"))
  end

  def test_replace_children_clears_and_inserts
    @root.replace_children(@doc.create_element("p"), "tail")
    assert_equal(1, @root.child_element_count)
    assert_equal("P", @root.children[0].tag_name)
    assert(@root.text_content.include?("tail"))
  end

  def test_replace_children_with_no_args_clears
    @root.replace_children
    assert_equal(0, @root.child_element_count)
  end

  def test_before_inserts_sibling
    @b.before(@doc.create_element("u"))
    assert_equal("U", @root.children[1].tag_name)
  end

  def test_after_inserts_sibling
    @a.after(@doc.create_element("u"))
    assert_equal("U", @root.children[1].tag_name)
  end

  def test_get_inner_html_alias
    assert_equal(@root.inner_html, @root.get_inner_html)
    assert_equal(@root.inner_html, @root.get_html)
  end

  def test_attributes_iteration_via_js_get
    @a.set_attribute("aria-label", "first")
    names = @a.attributes.map(&:name)
    assert_includes(names, "id")
    assert_includes(names, "aria-label")
  end

  def test_children_filters_to_elements_only
    @root.append(@doc.create_text_node(" sandwich "))
    @root.append(@doc.create_element("em"))
    assert(@root.child_element_count >= 2)
    @root.children.each do |c|
      assert_kind_of(Dommy::Element, c)
    end
  end

  def test_next_element_sibling_chain
    assert_equal("b", @a.next_element_sibling.id)
    assert_nil(@b.next_element_sibling)
  end

  def test_previous_element_sibling_chain
    assert_equal("a", @b.previous_element_sibling.id)
    assert_nil(@a.previous_element_sibling)
  end

  def test_node_name_uppercased
    assert_equal("DIV", @root.__js_get__("nodeName"))
  end

  def test_local_name_lowercased
    assert_equal("div", @root.local_name)
  end

  def test_xpath_scoped_to_element
    nodes = @root.xpath(".//span")
    assert_equal(2, nodes.size)
    assert_equal(%w[A B], nodes.map(&:text_content))
  end

  def test_at_xpath_returns_first_or_nil
    assert_equal("A", @root.at_xpath(".//span").text_content)
    assert_nil(@root.at_xpath(".//em"))
  end

  def test_path_returns_node_xpath
    assert_equal("/html/body/div/span[1]", @a.path)
  end
end
