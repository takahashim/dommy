# frozen_string_literal: true

require_relative "test_helper"

# Only an HTML document can be in quirks mode, so a type set after the parse
# — as dommy-rack sets the response's — decides the mode again, and the
# selector results that folded id and class case by the old one go.
class TestContentTypeQuirks < Minitest::Test
  def test_a_document_typed_as_xhtml_after_the_parse_leaves_quirks_mode
    doc = Dommy.parse("<html><body><p id=Foo class=Bar>x</p></body></html>").document
    assert_equal ["BackCompat", 1], [doc.compat_mode, doc.query_selector_all("#foo, .bar").length]

    doc.content_type = "application/xhtml+xml"
    assert_equal ["CSS1Compat", 0], [doc.compat_mode, doc.query_selector_all("#foo, .bar").length]
    assert_equal 1, doc.query_selector_all("#Foo").length
  end

  # A clone keeps its original's mode, typed as the original is.
  def test_a_clone_keeps_its_originals_mode
    doc = Dommy.parse("<html><body></body></html>").document
    assert_equal "BackCompat", doc.clone_node(false).compat_mode
  end
end
