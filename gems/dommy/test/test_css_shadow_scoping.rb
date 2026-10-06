# frozen_string_literal: true

require_relative "test_helper"

# CSS shadow-tree scoping (CSS Scoping 1; css-cascade.md): a shadow root's
# <style> participates in the cascade scoped to that shadow tree, with :host /
# :host() targeting the host and ::slotted() the assigned light DOM; ::part()
# from the document reaches a host's parts. Layout stays a non-goal — verified
# through getComputedStyle.
class TestCssShadowScoping < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window('<my-el id="host" class="dark"><span slot="s" id="light">L</span></my-el>')
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow("mode" => "open")
  end

  def color(element)
    @win.get_computed_style(element).get_property_value("color")
  end

  def test_host_styles_the_host
    @sr.inner_html = "<style>:host { color: rgb(1, 2, 3) }</style>"
    assert_equal "rgb(1, 2, 3)", color(@host)
  end

  def test_host_function_matches_host_condition
    @sr.inner_html = "<style>:host(.dark) { color: rgb(4, 5, 6) }</style>"
    assert_equal "rgb(4, 5, 6)", color(@host)
  end

  def test_host_function_no_match_when_condition_fails
    @sr.inner_html = "<style>:host(.light) { color: rgb(4, 5, 6) }</style>"
    assert_equal "rgb(0, 0, 0)", color(@host)
  end

  # Inside its shadow tree the host is featureless and its children are the
  # shadow root's: `:host:has()` looks at the shadow tree, never at the light
  # DOM, and a sibling relation never holds.
  def test_host_has_matches_against_the_shadow_tree
    @sr.inner_html = "<style>:host:has(.x) { color: rgb(1, 1, 1) }</style><div id='d'></div>"
    @host.append_child(@doc.create_element("b")).class_name = "x"
    assert_equal "rgb(0, 0, 0)", color(@host)

    @sr.get_element_by_id("d").class_name = "x"
    assert_equal "rgb(1, 1, 1)", color(@host)
  end

  def test_host_has_child_and_sibling_relations
    @sr.inner_html = "<style>:host:has(> .c) { color: rgb(2, 2, 2) } " \
                     ":host:has(~ .s) { background-color: rgb(3, 3, 3) }</style>" \
                     "<div class='c'></div>"
    @host.after(@doc.create_element("i").tap { |el| el.class_name = "s" })
    assert_equal "rgb(2, 2, 2)", color(@host)
    assert_equal "rgba(0, 0, 0, 0)", @win.get_computed_style(@host).get_property_value("background-color")
  end

  def test_host_compound_with_other_selectors_is_featureless
    @sr.inner_html = "<style>:host.dark { color: rgb(4, 4, 4) } :host(.dark):is(:host) { background-color: rgb(5, 5, 5) }</style>"
    assert_equal "rgb(0, 0, 0)", color(@host)
    assert_equal "rgb(5, 5, 5)", @win.get_computed_style(@host).get_property_value("background-color")
  end

  def test_shadow_internal_selector_scopes_to_shadow_tree
    @sr.inner_html = "<style>.btn { color: rgb(7, 8, 9) }</style><button class='btn' id='b'>B</button>"
    assert_equal "rgb(7, 8, 9)", color(@sr.get_element_by_id("b"))
  end

  def test_host_as_ancestor_of_shadow_descendant
    @sr.inner_html = "<style>:host(.dark) .inner { color: rgb(7, 8, 9) }</style>" \
                     "<div class='inner' id='i'>I</div>"
    assert_equal "rgb(7, 8, 9)", color(@sr.get_element_by_id("i"))
  end

  def test_slotted_styles_assigned_light_dom
    @sr.inner_html = "<style>::slotted(span) { color: rgb(10, 11, 12) }</style><slot name='s'></slot>"
    assert_equal "rgb(10, 11, 12)", color(@doc.get_element_by_id("light"))
  end

  # Encapsulation: a document rule must not reach into a shadow tree.
  def test_document_rule_does_not_cross_shadow_boundary
    @doc.head.inner_html = "<style>.btn { color: rgb(99, 0, 0) }</style>"
    @sr.inner_html = "<button class='btn' id='b'>B</button>"
    assert_equal "rgb(0, 0, 0)", color(@sr.get_element_by_id("b"))
  end

  # ::part() from a document style reaches a host's exposed parts.
  def test_part_from_document_style
    @doc.head.inner_html = "<style>my-el::part(label) { color: rgb(20, 20, 20) }</style>"
    @sr.inner_html = "<span part='label' id='p'>P</span>"
    assert_equal "rgb(20, 20, 20)", color(@sr.get_element_by_id("p"))
  end
end
