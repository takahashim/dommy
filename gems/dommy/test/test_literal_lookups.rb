# frozen_string_literal: true

require_relative "test_helper"

# getElementById, getElementsByClassName and getElementsByName compare an
# attribute with a string. None of them takes a CSS selector, so a value that
# would be special in one — a digit first, `.`, `:`, a quote, a backslash, a
# newline, NUL — must still be found, never raise.
class TestLiteralLookups < Minitest::Test
  include DommyTestHelper

  # The last ones are no ident code points of css-syntax-3 (§4.2), which
  # CSS.escape leaves as they are: U+000B, U+00A0, U+2000, U+200B, U+3000.
  EXOTIC = [
    "1", "-", "a.b", "a:b", "a'b", "a\\b", "[x]", "a\nb", "\u0000", "a\u0000b",
    "\u000B", "\u00A0", "\u2000", "\u200B", "\u3000", "a\u00A0b",
  ].freeze

  def setup
    @win = make_window("<div id=root></div>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
  end

  def child(parent, attrs)
    element = @doc.create_element("p")
    attrs.each { |name, value| element.set_attribute(name, value) }
    parent.append_child(element)
    element
  end

  def test_get_elements_by_class_name_on_an_element_takes_any_token
    EXOTIC.reject { |v| v.include?("\n") }.each do |token|
      element = child(@root, "class" => "x #{token}")

      assert_equal [element], @root.get_elements_by_class_name(token).to_a, token.inspect
      assert_equal [element], @doc.get_elements_by_class_name(token).to_a, token.inspect
    end
  end

  # In a quirks-mode document the class tokens compare ASCII
  # case-insensitively, on an element and on the document alike; a no-quirks
  # one keeps the case.
  def test_get_elements_by_class_name_ignores_ascii_case_in_quirks_mode
    quirks = Dommy::DOMParser.new.parse_from_string("<div id=r><p class=Foo></p><p class=\u00C9></p></div>", "text/html")
    assert_equal("BackCompat", quirks.compat_mode)
    assert_equal(1, quirks.get_element_by_id("r").get_elements_by_class_name("foo").length)
    assert_equal(1, quirks.get_elements_by_class_name("FOO").length)
    assert_equal(0, quirks.get_elements_by_class_name("\u00E9").length, "only ASCII folds")

    standard = Dommy::DOMParser.new.parse_from_string("<!DOCTYPE html><div id=r><p class=Foo></p></div>", "text/html")
    assert_equal(0, standard.get_element_by_id("r").get_elements_by_class_name("foo").length)
    assert_equal(0, standard.get_elements_by_class_name("foo").length)
  end

  def test_get_elements_by_name_takes_any_value
    EXOTIC.each do |name|
      element = child(@root, "name" => name)

      assert_equal [element], @doc.get_elements_by_name(name).to_a, name.inspect
    end
  end

  # Only HTML elements are found: an SVG or MathML element with the same
  # `name` is not.
  #
  # WPT: html/dom/documents/dom-tree-accessors/document.getElementsByName/document.getElementsByName-namespace.html
  def test_get_elements_by_name_finds_html_elements_only
    @root.inner_html = %(<p name="math"><math name="math"><mi>a</mi></math></p>) +
      %(<p name="svg"><svg name="svg"><rect name="svg"/></svg></p>)
    ps = @root.get_elements_by_tag_name("p").to_a

    assert_equal [ps[0]], @doc.get_elements_by_name("math").to_a
    assert_equal [ps[1]], @doc.get_elements_by_name("svg").to_a
  end

  # An element's id, classes and name are its attributes of those names in
  # no namespace: ones set with setAttributeNS in a namespace are not.
  #
  # Spec: https://dom.spec.whatwg.org/#concept-id
  def test_namespaced_id_class_and_name_attributes_are_not_looked_up
    other = child(@root, {})
    %w[id class name].each { |name| other.set_attribute_ns("urn:x", name, "v") }

    assert_nil @doc.get_element_by_id("v")
    assert_empty @doc.get_elements_by_class_name("v").to_a
    assert_empty @root.get_elements_by_class_name("v").to_a
    assert_empty @doc.get_elements_by_name("v").to_a

    element = child(@root, "id" => "v", "class" => "v", "name" => "v")
    assert_same element, @doc.get_element_by_id("v")
    assert_equal [element], @doc.get_elements_by_class_name("v").to_a
    assert_equal [element], @doc.get_elements_by_name("v").to_a
  end

  # Selectors and classList read the same attributes: an id or a class in a
  # namespace matches neither `#v` nor `.v`, and is none of classList's
  # tokens; a classList change writes the attribute in no namespace.
  def test_selectors_and_class_list_ignore_namespaced_id_and_class
    other = child(@root, {})
    other.set_attribute_ns("urn:x", "id", "w")
    other.set_attribute_ns("urn:x", "class", "w")

    assert_nil @doc.query_selector("#w")
    assert_nil @doc.query_selector(".w")
    refute other.matches?("#w")
    refute other.matches?(".w")
    refute other.matches?("div .w, p.w")
    assert_equal [], other.class_list.to_a

    other.class_list.add("z")
    assert_equal "w", other.get_attribute_ns("urn:x", "class")
    assert_equal "z", other.get_attribute_ns(nil, "class")
    assert_same other, @doc.query_selector(".z")
  end

  def test_get_element_by_id_takes_any_value
    fragment = @doc.create_document_fragment
    host = child(@root, {})
    shadow = host.attach_shadow({ "mode" => "open" })
    EXOTIC.each do |id|
      in_document = child(@root, "id" => id)
      in_fragment = child(fragment, "id" => id)
      in_shadow = child(shadow, "id" => id)

      assert_same in_document, @doc.get_element_by_id(id), id.inspect
      assert_same in_fragment, fragment.get_element_by_id(id), id.inspect
      assert_same in_shadow, shadow.get_element_by_id(id), id.inspect
    end
  end

  # CSSOM "serialize an identifier": a lone "-" is escaped, since by itself it
  # is a delim-token rather than an ident.
  def test_css_escape_escapes_a_lone_hyphen
    assert_equal "\\-", Dommy::CSSNamespace.escape("-")
    assert_equal "--", Dommy::CSSNamespace.escape("--")
    assert_equal "-a", Dommy::CSSNamespace.escape("-a")
  end
end
