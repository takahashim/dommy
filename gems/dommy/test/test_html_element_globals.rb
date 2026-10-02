# frozen_string_literal: true

require_relative "test_helper"

# The IDL attributes every HTML element has (HTMLElement and the mixins it
# includes): what each reads from its content attribute, and the default
# when there is none.
class TestHTMLElementGlobals < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window("<div id=host></div>").document
    @host = @doc.get_element_by_id("host")
  end

  def element(tag = "div", **attributes)
    el = @doc.create_element(tag)
    attributes.each { |name, value| el.set_attribute(name.to_s, value) }
    @host.append_child(el)
  end

  def test_plain_reflections
    el = element(accesskey: "k", autofocus: "", inert: "", headingreset: "", headingoffset: "3")
    assert_equal ["k", true, true, true, 3], %w[accessKey autofocus inert headingReset headingOffset].map { |k| el.__js_get__(k) }

    el.__js_set__("headingOffset", 20)
    assert_equal 8, el.__js_get__("headingOffset")
    plain = element
    assert_equal ["", false, false, false, 0], %w[accessKey autofocus inert headingReset headingOffset].map { |k| plain.__js_get__(k) }
  end

  # tabIndex reads the attribute as an integer, else 0 for the elements a
  # user can usually focus and -1 for the rest; SVG's `a` is one of them.
  def test_tab_index
    assert_equal [0, 0, -1, -1], [element("a"), element("button"), element, element("span")].map { |e| e.__js_get__("tabIndex") }
    details = element("details")
    first = details.append_child(@doc.create_element("summary"))
    second = details.append_child(@doc.create_element("summary"))
    assert_equal [0, -1], [first, second].map { |e| e.__js_get__("tabIndex") }
    assert_equal [5, -1], [element(tabindex: " 5x"), element(tabindex: "x")].map { |e| e.__js_get__("tabIndex") }

    svg = "http://www.w3.org/2000/svg"
    assert_equal [0, -1], [@doc.create_element_ns(svg, "a"), @doc.create_element_ns(svg, "g")].map { |e| e.__js_get__("tabIndex") }

    el = element
    el.__js_set__("tabIndex", 3)
    assert_equal ["3", 3], [el.get_attribute("tabindex"), el.__js_get__("tabIndex")]
  end

  # draggable is auto unless the attribute says "true" or "false": an img,
  # or an `a` with an href, is draggable then.
  def test_draggable
    assert_equal [true, true, false, false], [element("img"), element("a", href: "/"), element("a"), element].map { |e| e.__js_get__("draggable") }
    assert_equal [true, false], [element(draggable: "TRUE"), element("img", draggable: "false")].map { |e| e.__js_get__("draggable") }

    el = element
    el.__js_set__("draggable", true)
    assert_equal "true", el.get_attribute("draggable")
  end

  # spellcheck and writingSuggestions inherit from the parent when the
  # attribute says neither; the root's default is on.
  def test_inherited_hints
    outer = element(spellcheck: "false", writingsuggestions: "false")
    inner = outer.append_child(@doc.create_element("p"))
    assert_equal [false, "false"], %w[spellcheck writingSuggestions].map { |k| inner.__js_get__(k) }

    inner.set_attribute("spellcheck", "")
    inner.set_attribute("writingsuggestions", "TRUE")
    assert_equal [true, "true"], %w[spellcheck writingSuggestions].map { |k| inner.__js_get__(k) }
    assert_equal [true, "true"], %w[spellcheck writingSuggestions].map { |k| element.__js_get__(k) }

    inner.__js_set__("spellcheck", false)
    inner.__js_set__("writingSuggestions", "false")
    assert_equal ["false", "false"], [inner.get_attribute("spellcheck"), inner.get_attribute("writingsuggestions")]
  end

  # autocapitalize names the hint its keyword gives, and autocorrect is on
  # unless "off"; a form control that says nothing takes its form's.
  def test_autocapitalize_and_autocorrect
    assert_equal ["none", "sentences", "words", ""],
      [element(autocapitalize: "off"), element(autocapitalize: "On"), element(autocapitalize: "words"), element(autocapitalize: "x")].map { |e| e.__js_get__("autocapitalize") }

    form = element("form", autocapitalize: "characters", autocorrect: "off")
    input = form.append_child(@doc.create_element("input"))
    div = form.append_child(@doc.create_element("div"))
    assert_equal [["characters", false], ["", true]], [input, div].map { |e| [e.__js_get__("autocapitalize"), e.__js_get__("autocorrect")] }

    input.set_attribute("autocorrect", "")
    assert input.__js_get__("autocorrect")
    input.set_attribute("type", "email")
    refute input.__js_get__("autocorrect")

    div.__js_set__("autocorrect", false)
    assert_equal "off", div.get_attribute("autocorrect")
  end

  # contentEditable is the attribute's state; isContentEditable is whether
  # the element is an editing host or inside one, which `false` stops and
  # designMode starts; :read-write matches the same elements.
  def test_content_editable
    host = element(contenteditable: "")
    inner = host.append_child(@doc.create_element("p"))
    off = host.append_child(@doc.create_element("p"))
    off.set_attribute("contenteditable", "FALSE")
    assert_equal ["true", "inherit", "false"], [host, inner, off].map { |e| e.__js_get__("contentEditable") }
    assert_equal [true, true, false], [host, inner, off].map { |e| e.__js_get__("isContentEditable") }
    assert inner.matches?(":read-write")
    refute off.matches?(":read-write")

    inner.__js_set__("contentEditable", "Plaintext-Only")
    assert_equal "plaintext-only", inner.get_attribute("contenteditable")
    inner.__js_set__("contentEditable", "inherit")
    refute inner.has_attribute?("contenteditable")
    assert_raises(Dommy::DOMException::SyntaxError) { inner.__js_set__("contentEditable", "yes") }

    plain = element
    refute plain.__js_get__("isContentEditable")
    @doc.__js_set__("designMode", "on")
    assert plain.__js_get__("isContentEditable")
    refute @doc.create_element("p").__js_get__("isContentEditable"), "a detached element is in no document's design mode"
  end
end
