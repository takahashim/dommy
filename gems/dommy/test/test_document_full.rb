# frozen_string_literal: true

require_relative "test_helper"

# Round out Document coverage to match happy-dom's broader getter
# surface (URL/baseURI/domain/referrer/links/forms/scripts/images/
# children/childElementCount/firstElementChild/lastElementChild).
class TestDocumentFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <header><h1>Title</h1></header>
        <main>
          <a href="/a">A</a>
          <a href="/b">B</a>
          <form id="f1"><input name="x"></form>
          <form id="f2"></form>
          <script src="/s.js"></script>
          <img src="/i.png">
        </main>
      HTML
    )
    @doc = @win.document
  end

  def test_url_returns_location_href
    assert_equal(@win.location.href, @doc.url)
    assert_equal(@doc.url, @doc.__js_get__("URL"))
    assert_equal(@doc.url, @doc.__js_get__("documentURI"))
  end

  def test_base_uri_matches_url
    assert_equal(@doc.url, @doc.base_uri)
  end

  def test_domain_returns_hostname
    assert_equal("localhost", @doc.domain)
  end

  def test_referrer_empty
    assert_equal("", @doc.referrer)
  end

  def test_origin_matches_location_origin
    @win.location.__js_set__("href", "http://example.org/posts/1")
    assert_equal("http://example.org", @doc.origin)
    assert_equal(@doc.origin, @doc.__js_get__("origin"))
  end

  def test_content_type_defaults_to_text_html
    assert_equal("text/html", @doc.content_type)
    assert_equal("text/html", @doc.__js_get__("contentType"))
  end

  def test_content_type_is_settable
    @doc.content_type = "application/xhtml+xml"
    assert_equal("application/xhtml+xml", @doc.content_type)
    assert_equal("application/xhtml+xml", @doc.__js_get__("contentType"))
  end

  def test_to_html_serializes_document
    html = @doc.to_html
    assert_includes(html, "<h1>Title</h1>")
    assert_includes(html, "<html")
  end

  def test_at_xpath_returns_wrapped_element
    node = @doc.at_xpath("//h1")
    refute_nil(node)
    assert_equal("Title", node.text_content)
  end

  def test_at_xpath_returns_nil_when_missing
    assert_nil(@doc.at_xpath("//nonexistent"))
  end

  def test_xpath_returns_all_wrapped_elements
    nodes = @doc.xpath("//a")
    assert_equal(2, nodes.size)
    assert_equal("A", nodes[0].text_content)
  end

  def test_links_returns_anchors_with_href
    assert_equal(2, @doc.links.size)
    assert_equal("A", @doc.links[0].tag_name)
  end

  def test_forms_returns_form_elements
    assert_equal(2, @doc.forms.size)
    assert_equal("f1", @doc.forms[0].id)
  end

  def test_scripts_returns_script_elements
    assert_equal(1, @doc.scripts.size)
    assert_equal("/s.js", @doc.scripts[0].get_attribute("src"))
  end

  def test_images_returns_img_elements
    assert_equal(1, @doc.images.size)
    assert_equal("/i.png", @doc.images[0].get_attribute("src"))
  end

  def test_children_returns_root_element
    assert_equal(1, @doc.children.size)
    assert_equal("HTML", @doc.children[0].tag_name)
  end

  def test_child_element_count
    assert_equal(1, @doc.child_element_count)
  end

  def test_first_last_element_child
    refute_nil(@doc.first_element_child)
    refute_nil(@doc.last_element_child)
    assert_same(@doc.first_element_child.__dommy_backend_node__, @doc.last_element_child.__dommy_backend_node__)
  end

  def test_node_name_for_document
    assert_equal("#document", @doc.__js_get__("nodeName"))
  end

  def test_documentURI_alias
    assert_equal(@doc.url, @doc.__js_get__("documentURI"))
  end
end
