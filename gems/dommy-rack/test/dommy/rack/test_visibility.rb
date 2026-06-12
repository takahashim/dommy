# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestVisibility < Minitest::Test
  def el(html, selector)
    Dommy.parse(html).document.query_selector(selector)
  end

  def test_plain_element_is_visible
    assert Dommy::Rack.visible?(el("<p id='x'>hi</p>", "#x"))
  end

  def test_hidden_attribute
    refute Dommy::Rack.visible?(el("<p id='x' hidden>hi</p>", "#x"))
  end

  def test_input_type_hidden
    refute Dommy::Rack.visible?(el("<input id='x' type='hidden'>", "#x"))
  end

  def test_inline_display_none
    refute Dommy::Rack.visible?(el("<p id='x' style='display: none'>hi</p>", "#x"))
  end

  def test_inline_visibility_hidden
    refute Dommy::Rack.visible?(el("<p id='x' style='visibility:hidden'>hi</p>", "#x"))
  end

  def test_ancestor_display_none_hides_descendant
    node = el("<div style='display:none'><span id='x'>hi</span></div>", "#x")
    refute Dommy::Rack.visible?(node)
  end

  def test_nil_is_not_visible
    refute Dommy::Rack.visible?(nil)
  end

  def test_visible_input_with_other_style
    assert Dommy::Rack.visible?(el("<input id='x' type='text' style='color: red'>", "#x"))
  end
  def test_css_class_display_none_hides
    refute Dommy::Rack.visible?(
      el('<style>.hidden { display: none }</style><p id="x" class="hidden">x</p>', "#x")
    )
  end

  def test_css_class_on_ancestor_hides_descendant
    refute Dommy::Rack.visible?(
      el('<style>.hidden { display: none }</style><div class="hidden"><p id="x">x</p></div>', "#x")
    )
  end

  def test_css_visibility_hidden_is_overridable_by_descendant
    html = <<~HTML
      <style>.quiet { visibility: hidden } .loud { visibility: visible }</style>
      <div class="quiet"><p id="h">x</p><p id="s" class="loud">x</p></div>
    HTML
    doc = Dommy.parse(html).document
    refute Dommy::Rack.visible?(doc.query_selector("#h"))
    assert Dommy::Rack.visible?(doc.query_selector("#s"))
  end
end
