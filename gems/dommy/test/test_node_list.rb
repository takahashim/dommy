# frozen_string_literal: true

require_relative "test_helper"

class TestNodeListBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<ul><li>a</li><li>b</li><li>c</li></ul>")
    @doc = @win.document
    @items = @doc.query_selector_all("li")
  end

  def test_query_selector_all_returns_node_list
    assert_kind_of(Dommy::NodeList, @items)
  end

  def test_is_also_an_array
    assert_kind_of(Array, @items)
  end

  def test_length
    assert_equal(3, @items.length)
  end

  def test_index_accessor
    assert_equal("a", @items[0].text_content)
    assert_equal("c", @items[2].text_content)
  end

  def test_item_method
    assert_equal("a", @items.item(0).text_content)
    assert_equal("c", @items.item(2).text_content)
  end

  def test_item_out_of_range_returns_nil
    assert_nil(@items.item(99))
    assert_nil(@items.item(-1))
  end

  def test_for_each_yields_value_index_list
    seen = []
    @items.for_each { |value, index, list| seen << [value.text_content, index, list.length] }
    assert_equal([["a", 0, 3], ["b", 1, 3], ["c", 2, 3]], seen)
  end

  def test_for_each_camel_case_alias
    seen = []
    @items.forEach { |value, _index, _list| seen << value.text_content }
    assert_equal(["a", "b", "c"], seen)
  end

  def test_entries
    entries = @items.entries
    assert_equal(3, entries.size)
    assert_equal(0, entries[0][0])
    assert_equal("a", entries[0][1].text_content)
  end

  def test_keys
    assert_equal([0, 1, 2], @items.keys)
  end

  def test_values
    vals = @items.values
    assert_equal(["a", "b", "c"], vals.map(&:text_content))
  end

  def test_iterable_via_each
    seen = @items.map(&:text_content)
    assert_equal(["a", "b", "c"], seen)
  end

  def test_empty_node_list
    empty = @doc.query_selector_all(".nope")
    assert_kind_of(Dommy::NodeList, empty)
    assert_equal(0, empty.length)
    assert_nil(empty.item(0))
  end
end

class TestNodeListReturnedEverywhere < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <header>
          <a href='/a'>A</a>
          <a href='/b'>B</a>
        </header>
        <form><input name="x"></form>
        <img src="/x.png">
        <script src="/y.js"></script>
        <p class="primary"></p>
        <p class="primary big"></p>
      HTML
    )
    @doc = @win.document
  end

  def test_links_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @doc.links)
    assert_equal(2, @doc.links.length)
  end

  def test_forms_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @doc.forms)
  end

  def test_scripts_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @doc.scripts)
  end

  def test_images_is_html_collection
    assert_kind_of(Dommy::HTMLCollection, @doc.images)
  end

  def test_get_elements_by_tag_name_returns_live_html_collection
    list = @doc.get_elements_by_tag_name("a")
    assert_kind_of(Dommy::HTMLCollection, list)
    assert_equal(2, list.length)
  end

  def test_get_elements_by_name_returns_live_html_collection
    list = @doc.get_elements_by_name("x")
    assert_kind_of(Dommy::HTMLCollection, list)
  end

  def test_get_elements_by_class_name_returns_live_html_collection
    list = @doc.get_elements_by_class_name("primary")
    assert_kind_of(Dommy::HTMLCollection, list)
    assert_equal(2, list.length)
  end

  def test_element_query_selector_all_returns_node_list
    header = @doc.query_selector("header")
    list = header.query_selector_all("a")
    assert_kind_of(Dommy::NodeList, list)
    assert_equal(2, list.length)
  end
end

class TestNodeMixin < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='d'>text</div>")
    @doc = @win.document
  end

  def test_element_is_a_node
    el = @doc.get_element_by_id("d")
    assert_kind_of(Dommy::Node, el)
  end

  def test_text_node_is_a_node
    text = @doc.create_text_node("hi")
    assert_kind_of(Dommy::Node, text)
  end

  def test_comment_node_is_a_node
    comment = @doc.create_comment("hi")
    assert_kind_of(Dommy::Node, comment)
  end

  def test_fragment_is_a_node
    frag = @doc.create_document_fragment
    assert_kind_of(Dommy::Node, frag)
  end

  def test_document_is_a_node
    assert_kind_of(Dommy::Node, @doc)
  end

  def test_document_type_is_a_node
    assert_kind_of(Dommy::Node, @doc.doctype)
  end

  def test_shadow_root_is_a_node
    sr = @doc.get_element_by_id("d").attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::Node, sr)
  end

  def test_node_type_constants_on_module
    assert_equal(1, Dommy::Node::ELEMENT_NODE)
    assert_equal(3, Dommy::Node::TEXT_NODE)
    assert_equal(8, Dommy::Node::COMMENT_NODE)
    assert_equal(9, Dommy::Node::DOCUMENT_NODE)
    assert_equal(10, Dommy::Node::DOCUMENT_TYPE_NODE)
    assert_equal(11, Dommy::Node::DOCUMENT_FRAGMENT_NODE)
  end

  def test_document_position_constants_on_module
    assert_equal(0x01, Dommy::Node::DOCUMENT_POSITION_DISCONNECTED)
    assert_equal(0x02, Dommy::Node::DOCUMENT_POSITION_PRECEDING)
    assert_equal(0x04, Dommy::Node::DOCUMENT_POSITION_FOLLOWING)
    assert_equal(0x08, Dommy::Node::DOCUMENT_POSITION_CONTAINS)
    assert_equal(0x10, Dommy::Node::DOCUMENT_POSITION_CONTAINED_BY)
  end
end
