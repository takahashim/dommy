# frozen_string_literal: true

require_relative "../test_helper"

# `new StaticRange(init)`, and Selection.getComposedRanges(), which hands
# StaticRanges out. The expectations match Chrome 149 and Firefox 155.
#
# Spec: https://dom.spec.whatwg.org/#interface-staticrange
#       https://w3c.github.io/selection-api/#dom-selection-getcomposedranges
# WPT:  dom/ranges/StaticRange-constructor.html,
#       selection/shadow-dom/tentative/Selection-getComposedRanges.html
class TestWPTStaticRange < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='a'>abc</p><div id='host'></div>")
    @doc = @win.document
    @text = @doc.get_element_by_id("a").first_child
    @host = @doc.get_element_by_id("host")
    @sel = @doc.get_selection
  end

  def init(**members)
    { "startContainer" => @text, "startOffset" => 1, "endContainer" => @text, "endOffset" => 2 }
      .merge(members.transform_keys(&:to_s))
  end

  def points(range)
    [range.start_container, range.start_offset, range.end_container, range.end_offset]
  end

  # --- new StaticRange(init) ---------------------------------------------------

  def test_holds_the_points_it_was_given
    range = Dommy::StaticRange.from_init(init)
    assert_equal([@text, 1, @text, 2], points(range))
    assert_equal(false, range.__js_get__("collapsed"))
  end

  def test_offsets_are_converted_but_not_checked
    assert_equal([@text, 99, @text, 1], points(Dommy::StaticRange.from_init(init(startOffset: 99, endOffset: 1))))
    assert_equal(4_294_967_295, Dommy::StaticRange.from_init(init(startOffset: -1)).start_offset)
  end

  def test_a_doctype_or_attr_cannot_be_a_container
    doctype = @doc.implementation.create_document_type("x", "", "")
    assert_raises(Dommy::DOMException::InvalidNodeTypeError) { Dommy::StaticRange.from_init(init(startContainer: doctype)) }
    assert_raises(Dommy::DOMException::InvalidNodeTypeError) do
      Dommy::StaticRange.from_init(init(endContainer: @doc.create_attribute("x")))
    end
  end

  def test_every_member_is_required_and_containers_are_nodes
    assert_raises(Dommy::Bridge::TypeError) { Dommy::StaticRange.from_init(init.except("endOffset")) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::StaticRange.from_init(init(endOffset: Dommy::Bridge::UNDEFINED)) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::StaticRange.from_init(nil) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::StaticRange.from_init(init(startContainer: "x")) }
  end

  def test_it_does_not_follow_the_tree
    range = Dommy::StaticRange.from_init(init(startOffset: 3, endOffset: 3))
    @text.data = "a"
    assert_equal([@text, 3, @text, 3], points(range))
  end

  # --- Selection.getComposedRanges ----------------------------------------------

  def test_an_empty_selection_has_no_composed_ranges
    assert_equal([], @sel.get_composed_ranges)
  end

  def test_a_light_tree_selection_comes_back_as_a_new_static_range
    @sel.set_base_and_extent(@text, 2, @text, 1)
    ranges = @sel.get_composed_ranges
    assert_equal(1, ranges.size)
    assert_kind_of(Dommy::StaticRange, ranges.first)
    assert_equal([@text, 1, @text, 2], points(ranges.first))
    refute_same(ranges, @sel.get_composed_ranges)
  end

  def test_a_shadow_tree_not_listed_is_lifted_to_its_host
    shadow = @host.attach_shadow({ "mode" => "closed" })
    shadow.inner_html = "hello"
    text = shadow.first_child
    @sel.set_base_and_extent(text, 0, text, 5)

    assert_equal([@doc.body, 1, @doc.body, 2], points(@sel.get_composed_ranges.first))
    assert_equal([text, 0, text, 5], points(@sel.get_composed_ranges({ "shadowRoots" => [shadow] }).first))
    # A ShadowRoot on its own is an object without the member: nothing is listed.
    assert_equal([@doc.body, 1, @doc.body, 2], points(@sel.get_composed_ranges(shadow).first))
  end

  def test_listing_an_outer_shadow_root_lifts_a_point_only_out_of_the_inner_one
    outer = @host.attach_shadow({ "mode" => "open" })
    outer.inner_html = "<span></span>"
    inner = outer.first_child.attach_shadow({ "mode" => "open" })
    inner.inner_html = "deep"
    text = inner.first_child
    @sel.set_base_and_extent(text, 1, text, 3)

    assert_equal([outer, 0, outer, 1], points(@sel.get_composed_ranges({ "shadowRoots" => [outer] }).first))
    assert_equal([text, 1, text, 3], points(@sel.get_composed_ranges({ "shadowRoots" => [inner] }).first))
  end

  def test_shadow_roots_must_be_a_sequence_of_shadow_roots
    @sel.set_base_and_extent(@text, 0, @text, 1)
    assert_raises(Dommy::Bridge::TypeError) { @sel.get_composed_ranges({ "shadowRoots" => [@host] }) }
    assert_raises(Dommy::Bridge::TypeError) { @sel.get_composed_ranges({ "shadowRoots" => @host }) }
    assert_raises(Dommy::Bridge::TypeError) { @sel.get_composed_ranges("x") }
    @sel.remove_all_ranges
    assert_raises(Dommy::Bridge::TypeError) { @sel.get_composed_ranges({ "shadowRoots" => [@host] }) }
  end

  def test_over_the_bridge
    @sel.set_base_and_extent(@text, 0, @text, 1)
    ranges = @sel.__js_call__("getComposedRanges", [])
    assert_equal([@text, 0, @text, 1], points(ranges.first))
  end
end
