# frozen_string_literal: true

require_relative "test_helper"

# URL-reflecting IDL attributes — the ones HTML marks [ReflectURL] in its IDL.
# The getter parses the content attribute against the document and returns the
# serialization; the setter writes the attribute unchanged. Which attributes
# these are is checked against the specs' own IDL by test_webidl_conformance.rb;
# what the algorithm does is checked here.
# https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes
class TestUrlReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <base href="http://example.test/base/sub/">
      <img id="img" src="pic.png">
      <a id="a" href="pic.png">a</a>
    HTML
    @doc = @win.document
    @img = @doc.get_element_by_id("img")
  end

  def test_the_getter_resolves_against_the_document_base_url
    assert_equal("http://example.test/base/sub/pic.png", @img.src)
  end

  # "If contentAttributeValue is null, then return the empty string."
  def test_an_absent_attribute_is_the_empty_string
    @img.remove_attribute("src")

    assert_equal("", @img.src)
  end

  # An EMPTY attribute is not absent: it parses, and what it parses to is the
  # base URL. This is why "does this element name a resource" asks the content
  # attribute rather than the property.
  def test_an_empty_attribute_resolves_to_the_base_url
    @img.set_attribute("src", "")

    assert_equal("http://example.test/base/sub/", @img.src)
    assert_equal("", @img.get_attribute("src"))
  end

  # "Return contentAttributeValue" — a value that does not parse reads back as
  # written rather than raising or emptying.
  def test_an_unparseable_value_reads_back_as_written
    @img.set_attribute("src", "http://[bad")

    assert_equal("http://[bad", @img.src)
  end

  # The setter reflects, and only the getter resolves: the attribute keeps what
  # was assigned to it.
  def test_the_setter_writes_the_attribute_unchanged
    @img.src = "other/pic.png"

    assert_equal("other/pic.png", @img.get_attribute("src"))
    assert_equal("http://example.test/base/sub/other/pic.png", @img.src)
  end

  # A URL attribute and HTMLHyperlinkElementUtils are two implementations of one
  # resolution, so they must agree.
  def test_it_agrees_with_the_hyperlink_getter
    assert_equal(@doc.get_element_by_id("a").href, @img.src)
  end

  # `action` and `formAction` are [ReflectSetter]: a missing OR empty attribute
  # reports the document's own address, because a form with no action posts to
  # the page it is on.
  def test_a_form_with_no_action_reports_the_documents_url
    form = @doc.create_element("form")
    @doc.body.append_child(form)

    assert_equal(@doc.url.to_s, form.action)

    form.set_attribute("action", "")

    assert_equal(@doc.url.to_s, form.action)

    form.set_attribute("action", "post")

    assert_equal("http://example.test/base/sub/post", form.action)
  end
end
