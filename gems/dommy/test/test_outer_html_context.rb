# frozen_string_literal: true

require_relative "test_helper"

# outerHTML parses in its parent as context, an `html` element included:
# only insertAdjacentHTML and createContextualFragment parse an `html`
# context as a `body`.
class TestOuterHtmlContext < Minitest::Test
  def setup
    @doc = Dommy.parse("<!doctype html><html><head><title>a</title></head><body><p>x</p></body></html>").document
  end

  # In the `html` context the parser builds the head it implies, then the
  # body — so the new body keeps its attributes, beside an empty head.
  def test_a_body_replaced_through_outer_html_is_a_body
    @doc.body.outer_html = "<body class=x>hi</body>"
    assert_equal ["x", "hi"], [@doc.body.class_name, @doc.body.text_content]
    assert_equal %w[head head body], @doc.document_element.children.map(&:local_name)
  end

  def test_a_head_replaced_through_outer_html_keeps_its_title
    @doc.head.outer_html = "<head><title>t</title></head>"
    assert_equal ["t", %w[title]], [@doc.title, @doc.head.children.map(&:local_name)]
  end

  def test_insert_adjacent_html_on_the_html_element_still_parses_as_body
    @doc.document_element.insert_adjacent_html("beforeend", "<head></head><b>y</b>")
    assert_equal %w[head body b], @doc.document_element.children.map(&:local_name)
  end
end
