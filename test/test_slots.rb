# frozen_string_literal: true

require_relative "test_helper"

class TestSlotBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="host">
          <p>Light A</p>
          <span slot="header">Light B</span>
          <em>Light C</em>
        </div>
      HTML
    )
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = <<~SHADOW
      <header><slot name='header'>fallback header</slot></header>
      <main><slot>fallback default</slot></main>
    SHADOW
    @default_slot = @sr.query_selector("slot:not([name])")
    @named_slot = @sr.query_selector("slot[name='header']")
  end

  def test_slot_element_is_html_slot
    assert_kind_of(Dommy::HTMLSlotElement, @default_slot)
    assert_kind_of(Dommy::HTMLSlotElement, @named_slot)
  end

  def test_default_slot_name_empty
    assert_equal("", @default_slot.name)
  end

  def test_named_slot_name
    assert_equal("header", @named_slot.name)
  end

  def test_default_slot_assigned_nodes
    nodes = @default_slot.assigned_nodes
    tags = nodes.map { |n| n.respond_to?(:tag_name) ? n.tag_name : nil }
    assert_includes(tags, "P")
    assert_includes(tags, "EM")
    refute_includes(tags, "SPAN")
  end

  def test_named_slot_assigned_nodes
    nodes = @named_slot.assigned_nodes
    assert_equal(1, nodes.size)
    assert_equal("SPAN", nodes.first.tag_name)
    assert_equal("Light B", nodes.first.text_content)
  end

  def test_assigned_elements_filters_to_elements
    els = @default_slot.assigned_elements
    els.each { |e| assert_kind_of(Dommy::Element, e) }
  end

  def test_assigned_nodes_flatten_false_no_fallback
    # no light children
    @host.inner_html = ""
    nodes = @default_slot.assigned_nodes
    assert_empty(nodes)
  end

  def test_assigned_nodes_flatten_true_uses_fallback
    @host.inner_html = ""
    nodes = @default_slot.assigned_nodes({"flatten" => true})
    # Fallback = slot's own children ("fallback default" text node).
    assert_operator(nodes.size, :>=, 1)
    assert_equal("fallback default", nodes.map(&:text_content).join.strip)
  end
end

class TestSlotChangeOnAssignment < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @host = @win.document.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    @sr.inner_html = "<slot id='s'></slot>"
    @slot = @sr.get_element_by_id("s")
  end

  def test_assign_fires_slotchange_event
    fired = false
    @slot.add_event_listener("slotchange", proc { fired = true })
    @slot.assign(@win.document.create_element("p"))
    assert(fired)
  end

  def test_manual_assigned_nodes_returns_assigned_list
    p1 = @win.document.create_element("p")
    p2 = @win.document.create_element("p")
    @slot.assign(p1, p2)
    nodes = @slot.assigned_nodes
    assert_equal(2, nodes.size)
  end
end

class TestNestedShadow < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<my-card id='host'><h1>Title</h1></my-card>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<div class='wrapper'><slot></slot></div>"
  end

  def test_slot_inside_wrapper_finds_light_dom
    slot = @sr.query_selector("slot")
    nodes = slot.assigned_nodes
    assert_equal(1, nodes.size)
    assert_equal("H1", nodes.first.tag_name)
  end

  def test_slot_returns_empty_when_outside_shadow
    detached_slot = @doc.create_element("slot")
    assert_empty(detached_slot.assigned_nodes)
  end
end
