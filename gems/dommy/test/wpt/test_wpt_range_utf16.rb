# frozen_string_literal: true

require_relative "../test_helper"

# DOM string offsets are UTF-16 code unit indices, so an astral character (here
# U+1F600) counts as TWO. Ruby's String#length and String#[] count code points,
# which is why every Range boundary offset has to go through the shared
# Internal::Utf16 helpers rather than native Ruby indexing.
#
# For the text "A😀BC" the code unit map is:
#   A = [0,1)   😀 = [1,3)   B = [3,4)   C = [4,5)   length = 5
#
# Every expectation below was cross-checked against headless Chromium.
#
# WPT: dom/ranges/Range-set.html, dom/ranges/Range-cloneContents.html,
#      dom/ranges/Range-extractContents.html, dom/ranges/Range-deleteContents.html,
#      dom/ranges/Range-mutations-splitText.html, dom/ranges/Range-stringifier.html
# Spec: https://dom.spec.whatwg.org/#concept-range-bp
class TestWPTRangeUtf16Offsets < Minitest::Test
  include DommyTestHelper

  EMOJI = "A\u{1F600}BC"

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @text = text_node
    @range = @doc.create_range
  end

  # A fresh text node, since most of these mutate it.
  def text_node
    @host.inner_html = "<p id='p'></p>"
    para = @doc.get_element_by_id("p")
    node = @doc.create_text_node(EMOJI)
    para.append_child(node)
    node
  end

  def test_character_data_length_counts_code_units
    assert_equal(5, @text.length)
  end

  def test_setEnd_accepts_the_last_code_unit_and_rejects_one_past_it
    @range.set_start(@text, 0)
    @range.set_end(@text, 5) # no raise
    assert_equal(5, @range.end_offset)
    assert_raises(Dommy::DOMException::IndexSizeError) { @range.set_end(@text, 6) }
  end

  def test_stringifier_slices_on_code_units
    @range.set_start(@text, 1)
    @range.set_end(@text, 4)
    assert_equal("\u{1F600}B", @range.to_s)
  end

  def test_cloneContents_slices_on_code_units
    @range.set_start(@text, 1)
    @range.set_end(@text, 4)
    assert_equal("\u{1F600}B", @range.clone_contents.text_content)
    assert_equal(EMOJI, @text.data, "cloneContents must leave the source alone")
  end

  def test_extractContents_after_the_astral_character
    @range.set_start(@text, 3)
    @range.set_end(@text, 5)
    assert_equal("BC", @range.extract_contents.text_content)
    assert_equal("A\u{1F600}", @text.data)
    assert_equal(3, @range.start_offset)
  end

  def test_extractContents_of_exactly_the_astral_character
    @range.set_start(@text, 1)
    @range.set_end(@text, 3)
    assert_equal("\u{1F600}", @range.extract_contents.text_content)
    assert_equal("ABC", @text.data)
  end

  # deleteContents inside one CharacterData node is a "replace data", so the
  # collapsed boundary stays at the start offset instead of clamping to 0.
  def test_deleteContents_of_the_astral_character
    @range.set_start(@text, 1)
    @range.set_end(@text, 3)
    @range.delete_contents
    assert_equal("ABC", @text.data)
    assert_equal([1, 1], [@range.start_offset, @range.end_offset])
  end

  # ---- live boundaries across CharacterData mutations ----

  def test_insertData_before_the_astral_character_shifts_boundaries
    @range.set_start(@text, 3)
    @range.set_end(@text, 4)
    @text.insert_data(1, "XY")
    assert_equal("AXY\u{1F600}BC", @text.data)
    assert_equal([5, 6], [@range.start_offset, @range.end_offset])
  end

  def test_deleteData_before_the_astral_character_shifts_boundaries
    @range.set_start(@text, 3)
    @range.set_end(@text, 5)
    @text.delete_data(0, 1)
    assert_equal("\u{1F600}BC", @text.data)
    assert_equal([2, 4], [@range.start_offset, @range.end_offset])
  end

  def test_replaceData_before_the_astral_character_shifts_boundaries
    @range.set_start(@text, 3)
    @range.set_end(@text, 5)
    @text.replace_data(0, 1, "ZZZ")
    assert_equal("ZZZ\u{1F600}BC", @text.data)
    assert_equal([5, 7], [@range.start_offset, @range.end_offset])
  end

  # splitText at a code unit offset past the astral character: the tail boundary
  # follows the data into the new node.
  def test_splitText_on_a_code_unit_offset_moves_the_tail_boundary
    @range.set_start(@text, 1)
    @range.set_end(@text, 5)
    tail = @text.split_text(3)
    assert_equal(["A\u{1F600}", "BC"], [@text.data, tail.data])
    assert_equal(1, @range.start_offset)
    assert_same(tail, @range.end_container)
    assert_equal(2, @range.end_offset)
  end

  # A DETACHED text node skips the split steps entirely (they only run when the
  # node has a parent), so the boundary stays put and is clamped by the
  # truncation instead.
  def test_splitText_on_a_detached_node_clamps_instead_of_moving
    detached = @doc.create_text_node(EMOJI)
    @range.set_start(detached, 1)
    @range.set_end(detached, 5)
    detached.split_text(3)
    assert_same(detached, @range.end_container)
    assert_equal([1, 3], [@range.start_offset, @range.end_offset])
  end

  # Splitting a surrogate pair down the middle would need a lone surrogate,
  # which a Ruby String cannot hold — Dommy fails loud rather than mangling it.
  def test_splitting_a_surrogate_pair_fails_loud
    error = assert_raises(RuntimeError) { @text.substring_data(2, 1) }
    assert_match(/surrogate pair/, error.message)
  end
end
