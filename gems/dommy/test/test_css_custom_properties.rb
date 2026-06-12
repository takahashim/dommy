# frozen_string_literal: true

require_relative "test_helper"

# Custom properties + var() substitution (css-variables-1; css-cascade.md P3).
class TestCssCustomProperties < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade

  def doc_for(html)
    Dommy.parse(html).document
  end

  def computed(doc, id)
    CASCADE.computed_style(doc.get_element_by_id(id))
  end

  def test_var_substitutes_and_normalizes
    doc = doc_for(<<~HTML)
      <style>
        :root { --main: #ff0000 }
        #x { color: var(--main) }
      </style>
      <p id="x">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_custom_properties_inherit_and_can_be_overridden_in_a_subtree
    doc = doc_for(<<~HTML)
      <style>
        :root { --c: red }
        .theme { --c: green }
        p { color: var(--c) }
      </style>
      <p id="outside">x</p>
      <div class="theme"><p id="inside">x</p></div>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "outside")["color"]
    assert_equal "rgb(0, 128, 0)", computed(doc, "inside")["color"]
  end

  def test_fallback_is_used_when_the_property_is_missing
    doc = doc_for('<style>#x { color: var(--missing, blue) }</style><p id="x">x</p>')
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_fallback_may_contain_commas_and_nested_var
    doc = doc_for(<<~HTML)
      <style>
        :root { --fam: Arial }
        #x { font-family: var(--missing, var(--fam), serif) }
      </style>
      <p id="x">x</p>
    HTML
    # The fallback is everything after the first top-level comma.
    assert_equal "Arial, serif", computed(doc, "x")["font-family"]
  end

  def test_missing_var_without_fallback_behaves_as_unset
    doc = doc_for(<<~HTML)
      <style>
        #outer { color: green }
        #x { color: var(--missing); background-color: var(--missing) }
      </style>
      <div id="outer"><p id="x">x</p></div>
    HTML
    styles = computed(doc, "x")
    # color inherits (unset on an inherited property)...
    assert_equal "rgb(0, 128, 0)", styles["color"]
    # ...background-color resets to its initial (non-inherited).
    assert_equal "rgba(0, 0, 0, 0)", styles["background-color"]
  end

  def test_custom_property_built_from_another_custom_property
    doc = doc_for(<<~HTML)
      <style>
        :root { --hue: 255, 0, 0; --main: rgb(var(--hue)) }
        #x { color: var(--main) }
      </style>
      <p id="x">x</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "x")["color"]
  end

  def test_cycles_invalidate_all_participants
    doc = doc_for(<<~HTML)
      <style>
        :root { --a: var(--b); --b: var(--a) }
        #outer { color: green }
        #x { color: var(--a) }
      </style>
      <div id="outer"><p id="x">x</p></div>
    HTML
    assert_equal "rgb(0, 128, 0)", computed(doc, "x")["color"]
  end

  def test_cycle_participants_are_invalid_fallback_notwithstanding
    doc = doc_for(<<~HTML)
      <style>
        :root { --a: var(--b, blue); --b: var(--a) }
        #x { color: var(--a, green) }
      </style>
      <p id="x">x</p>
    HTML
    # --a is in the cycle, so its own fallback does NOT save it
    # (css-variables-1 §3.1); referencing it from outside may use the
    # reference's fallback though.
    assert_equal "rgb(0, 128, 0)", computed(doc, "x")["color"]
  end

  def test_reference_to_a_cyclic_property_can_use_its_fallback
    doc = doc_for(<<~HTML)
      <style>
        :root { --a: var(--b); --b: var(--a); --safe: var(--a, blue) }
        #x { color: var(--safe) }
      </style>
      <p id="x">x</p>
    HTML
    assert_equal "rgb(0, 0, 255)", computed(doc, "x")["color"]
  end

  def test_initial_removes_an_inherited_custom_property
    doc = doc_for(<<~HTML)
      <style>
        :root { --c: red }
        #outer { color: green }
        #inner { --c: initial; color: var(--c) }
      </style>
      <div id="outer"><p id="inner">x</p></div>
    HTML
    # --c is guaranteed-invalid on #inner, so color behaves as unset.
    assert_equal "rgb(0, 128, 0)", computed(doc, "inner")["color"]
  end

  def test_custom_property_names_are_case_sensitive
    doc = doc_for(<<~HTML)
      <style>
        :root { --Main: red }
        #a { color: var(--Main) }
        #b { color: var(--main, blue) }
      </style>
      <p id="a">a</p><p id="b">b</p>
    HTML
    assert_equal "rgb(255, 0, 0)", computed(doc, "a")["color"]
    assert_equal "rgb(0, 0, 255)", computed(doc, "b")["color"]
  end

  def test_inline_style_custom_properties_participate
    doc = doc_for(<<~HTML)
      <style>#x { color: var(--c) }</style>
      <p id="x" style="--c: rebeccapurple">x</p>
    HTML
    assert_equal "rgb(102, 51, 153)", computed(doc, "x")["color"]
  end

  def test_get_computed_style_exposes_custom_properties
    doc = doc_for('<style>:root { --gap: 12px }</style><p id="x">x</p>')
    declaration = doc.default_view.get_computed_style(doc.get_element_by_id("x"))
    assert_equal "12px", declaration.get_property_value("--gap")
    assert_equal "", declaration.get_property_value("--missing")
  end

  def test_tailwind_style_layered_variables_resolve
    doc = doc_for(<<~HTML)
      <style>
        :root { --tw-color-red-500: #ef4444; --tw-bg: var(--tw-color-red-500) }
        .bg-red-500 { background-color: var(--tw-bg) }
      </style>
      <button id="x" class="bg-red-500">x</button>
    HTML
    assert_equal "rgb(239, 68, 68)", computed(doc, "x")["background-color"]
  end
end
