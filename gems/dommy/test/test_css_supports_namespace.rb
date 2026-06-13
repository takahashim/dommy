# frozen_string_literal: true

require_relative "test_helper"

# window.CSS.supports() — both the (property, value) declaration form and the
# (conditionText) form, backed by the same @supports evaluator the cascade uses.
class TestCSSSupportsNamespace < Minitest::Test
  def css
    @css ||= Dommy::CSSNamespace.new
  end

  def supports(*args)
    css.__js_call__("supports", args)
  end

  def test_two_argument_declaration_form
    assert supports("display", "grid")
    assert supports("color", "red")
  end

  def test_two_argument_rejects_empty
    refute supports("display", "")
    refute supports("", "grid")
  end

  def test_condition_form_parenthesized
    assert supports("(display: grid)")
    refute supports("(display:)")
  end

  def test_condition_form_combinators
    assert supports("(display: grid) and (color: red)")
    assert supports("(display: grid) or (foo: bar)")
    refute supports("not (display: grid)")
  end

  def test_condition_form_selector_function
    assert supports("selector(a:hover)")
    refute supports("selector(##bad)")
  end

  def test_bare_declaration_without_parens_is_not_a_condition
    refute supports("display: grid")
  end

  def test_exposed_on_window
    win = Dommy::Window.new
    css = win.__js_get__("CSS")
    assert css.__js_call__("supports", ["(display: grid)"])
  end
end
