# frozen_string_literal: true

require_relative "test_helper"

# What an element has depends on its interface, not on Element: HTML, SVG
# and MathML elements include the HTMLOrSVGOrMathMLElement mixin, and an
# element in no namespace, or in any other, is a plain Element without it.
class TestHTMLOrSVGOrMathMLElement < Minitest::Test
  include DommyTestHelper

  NAMESPACES = {
    html: "http://www.w3.org/1999/xhtml",
    svg: "http://www.w3.org/2000/svg",
    mathml: "http://www.w3.org/1998/Math/MathML",
  }.freeze

  def setup
    @doc = make_window("").document
  end

  def element(namespace, name = "a")
    el = @doc.create_element_ns(namespace, name)
    el.set_attribute("data-foo-bar", "v")
    el.set_attribute("tabindex", "2")
    @doc.body.append_child(el)
  end

  MIXIN = %w[dataset nonce autofocus tabIndex].freeze

  def test_the_mixin_is_on_html_svg_and_mathml_elements
    NAMESPACES.each do |kind, namespace|
      el = element(namespace)
      MIXIN.each { |key| refute_equal Dommy::Bridge::ABSENT, el.__js_get__(key), "#{kind} #{key}" }
      assert_equal "v", el.dataset.__js_get__("fooBar"), kind.to_s
      assert_equal 2, el.__js_get__("tabIndex"), kind.to_s
      assert_includes el.class.js_method_names, "focus", kind.to_s
    end
  end

  # dataset, nonce, autofocus, tabIndex, focus and blur are absent on an
  # element in no namespace or another one — `el.dataset.fooBar` throws.
  def test_a_plain_element_has_none_of_it
    [nil, "urn:x"].each do |namespace|
      el = element(namespace)
      assert_equal Dommy::Element, el.class
      MIXIN.each { |key| assert_equal Dommy::Bridge::ABSENT, el.__js_get__(key), "#{namespace.inspect} #{key}" }
      refute el.respond_to?(:dataset)
      refute el.respond_to?(:focus)
      refute_includes el.class.js_method_names, "focus"
    end
  end

  # A MathML element is a MathMLElement, and focusable like the others.
  def test_a_mathml_element_is_a_mathml_element
    el = element(NAMESPACES[:mathml], "mi")
    assert_kind_of Dommy::MathMLElement, el
    el.focus
    assert_same el, @doc.active_element
    assert_equal(-1, @doc.create_element_ns(NAMESPACES[:mathml], "mi").__js_get__("tabIndex"))
  end

  HTML_ONLY = %w[hidden translate value popover accessKeyLabel offsetParent offsetTop offsetLeft offsetWidth offsetHeight].freeze

  # HTMLElement's own attributes are on HTML elements only.
  def test_html_element_attributes_are_on_html_elements_only
    html = element(NAMESPACES[:html], "div")
    HTML_ONLY.each { |key| refute_equal Dommy::Bridge::ABSENT, html.__js_get__(key), key }
    [nil, "urn:x", NAMESPACES[:svg], NAMESPACES[:mathml]].each do |namespace|
      el = element(namespace, "x")
      HTML_ONLY.each { |key| assert_equal Dommy::Bridge::ABSENT, el.__js_get__(key), "#{namespace.inspect} #{key}" }
    end
    %w[href content parent].each { |key| assert_equal Dommy::Bridge::ABSENT, element(nil, "x").__js_get__(key), key }
  end

  # popover is limited to its keywords.
  def test_popover
    div = element(NAMESPACES[:html], "div")
    assert_nil div.__js_get__("popover")
    { "" => "auto", "Hint" => "hint", "x" => "manual" }.each do |value, keyword|
      div.set_attribute("popover", value)
      assert_equal keyword, div.__js_get__("popover"), value
    end
  end
end
