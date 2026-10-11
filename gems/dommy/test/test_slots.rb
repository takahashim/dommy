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

  # "Notify mutation observers": the pending observers' callbacks run first,
  # in the order their registrations were reached, and slotchange fires after
  # them, in the same microtask.
  def test_slotchange_fires_after_the_mutation_observers
    order = []
    first = Dommy::MutationObserver.new(@win, proc { order << :first })
    second = Dommy::MutationObserver.new(@win, proc { order << :second })
    second.__js_call__("observe", [@host, {"childList" => true}])
    first.__js_call__("observe", [@host, {"childList" => true}])
    @default_slot.add_event_listener("slotchange", proc { order << :slotchange })

    @host.append_child(@doc.create_element("b"))
    @win.scheduler.drain_microtasks
    assert_equal %i[second first slotchange], order
  end

  # The slots that fire slotchange once the pending signals have run.
  def slotchanges_after
    @win.scheduler.drain_microtasks
    fired = []
    @sr.query_selector_all("slot").each do |slot|
      slot.add_event_listener("slotchange", proc { fired << (slot.get_attribute("name") || "") })
    end
    yield
    @win.scheduler.drain_microtasks
    fired
  end

  # Which slot a slottable finds depends on the tree's slots alone, so a
  # shadow-tree change that brings in no slot moves nothing.
  def test_a_non_slot_coming_into_the_shadow_tree_signals_nothing
    assert_empty(slotchanges_after { @sr.query_selector("main").append_child(@doc.create_element("div")) })
  end

  # A slot inserted ahead of another with its name takes that slot's nodes.
  def test_a_slot_wrapped_in_an_insertion_takes_the_nodes_of_a_later_one
    wrapper = @doc.create_element("div")
    wrapper.inner_html = "<span><slot></slot></span>"
    inserted = wrapper.query_selector("slot")
    fired_on_inserted = false
    inserted.add_event_listener("slotchange", proc { fired_on_inserted = true })
    taken = @default_slot.assigned_nodes
    fired = slotchanges_after { @sr.insert_before(wrapper, @sr.first_element_child) }
    assert_equal [""], fired
    assert fired_on_inserted
    assert_empty @default_slot.assigned_nodes
    assert_equal taken, inserted.assigned_nodes
  end

  # A slot leaving inside a removed subtree loses its nodes to the next slot
  # with its name, and both are signaled: the tree's slots first, then the
  # removed one (DOM "remove" step 14).
  def test_a_slot_removed_inside_a_subtree_hands_its_nodes_on
    @sr.append_child(@doc.create_element("aside")).inner_html = "<slot name='header'></slot>"
    @win.scheduler.drain_microtasks
    taken = @named_slot.assigned_nodes
    later = @sr.query_selector("aside slot")
    fired = []
    [later, @named_slot].each { |slot| slot.add_event_listener("slotchange", proc { fired << slot }) }
    @sr.query_selector("header").remove
    @win.scheduler.drain_microtasks
    assert_empty @named_slot.assigned_nodes
    assert_equal taken, later.assigned_nodes
    assert_equal [later, @named_slot], fired
  end

  # A change outside every shadow tree, away from any host, signals nothing.
  def test_a_light_tree_change_away_from_hosts_signals_nothing
    other = @doc.body.append_child(@doc.create_element("section"))
    assert_empty(slotchanges_after { other.inner_html = "<slot></slot><p></p>" })
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

  # `assignedSlot` is the slottable's view of the composition `assignedNodes`
  # describes from the slot's side: a light-DOM child reports which slot it
  # composes into.
  def test_assigned_slot_default
    p = @host.query_selector("p")
    assert_same(@default_slot, p.assigned_slot)
  end

  def test_assigned_slot_named
    span = @host.query_selector("span")
    assert_same(@named_slot, span.assigned_slot)
  end

  def test_assigned_slot_nil_without_matching_slot
    # A light child targeting a slot name that the shadow tree doesn't expose.
    @host.inner_html = "<i slot='missing'>x</i>"
    assert_nil(@host.query_selector("i").assigned_slot)
  end

  def test_assigned_slot_nil_for_non_slotted_element
    # An element that isn't a direct child of a shadow host has no assigned slot.
    assert_nil(@default_slot.assigned_slot)
  end

  def test_assigned_slot_nil_for_closed_shadow
    # The "open flag": a closed shadow tree hides the assignment.
    win = make_window("<div id='h'><p>x</p></div>")
    host = win.document.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "closed"})
    sr.inner_html = "<slot></slot>"
    assert_nil(host.query_selector("p").assigned_slot)
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

  # slotchange is signaled, so it fires in a microtask, not during assign().
  def test_assign_fires_slotchange_event
    fired = false
    @slot.add_event_listener("slotchange", proc { fired = true })
    @slot.assign(@host.append_child(@win.document.create_element("p")))
    refute(fired)
    @win.scheduler.drain_microtasks
    assert(fired)
  end

  # Only the host's children among the assigned nodes are slotted, in the
  # order they were assigned.
  def test_manual_assigned_nodes_are_the_hosts_children_in_assignment_order
    p1 = @host.append_child(@win.document.create_element("p"))
    p2 = @host.append_child(@win.document.create_element("p"))
    stray = @win.document.create_element("p")
    @slot.assign(p2, stray, p1)
    assert_equal([p2, p1], @slot.assigned_nodes)
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

# The slot changes worked out from each mutation (Internal::SlotSignals), and
# the slots DOM's "find a slot" sees.
class TestSlotChangeSignals < Minitest::Test
  include DommyTestHelper

  def setup
    @win = Dommy.parse(<<~HTML)
      <div id="h"><template shadowrootmode="open"><slot name="a"></slot><slot name="b"></slot><slot></slot></template><span slot="a">A</span></div>
    HTML
    @doc = @win.document
    @host = @doc.get_element_by_id("h")
    @sr = @host.shadow_root
  end

  def slot(name) = @sr.query_selector(name.empty? ? "slot:not([name])" : "slot[name='#{name}']")

  def fired_after
    @win.scheduler.drain_microtasks
    fired = []
    @sr.query_selector_all("slot").each do |s|
      s.add_event_listener("slotchange", proc { fired << s.get_attribute("name").to_s })
    end
    yield
    @win.scheduler.drain_microtasks
    fired
  end

  # A parsed declarative shadow tree's slots start out with what they have:
  # only the slot that gains a node is signaled.
  def test_a_declarative_tree_signals_only_the_slot_that_changed
    child = @doc.create_element("i")
    child.set_attribute("slot", "b")
    assert_equal ["b"], fired_after { @host.append_child(child) }
  end

  def test_a_slottable_added_to_the_host_signals_its_slot_only
    assert_equal [""], fired_after { @host.append_child(@doc.create_element("i")) }
    assert_equal [], fired_after { @host.append_child(@doc.create_comment("c")) }
  end

  def test_a_slot_attribute_change_signals_the_old_and_the_new_slot
    span = @host.query_selector("span")
    assert_equal %w[a b], fired_after { span.set_attribute("slot", "b") }.sort
    assert_equal [], fired_after { span.set_attribute("slot", "b") }
  end

  # Renaming a slot to a name an earlier slot has hands nothing over; renaming
  # the first slot of a name the host uses moves its nodes on.
  def test_renaming_a_slot
    assert_equal [], fired_after { slot("b").set_attribute("name", "z") }
    fired = fired_after { slot("a").set_attribute("name", "y") }
    assert_equal ["y"], fired
    assert_empty @sr.query_selector("slot[name='y']").assigned_nodes
  end

  # An SVG or MathML <slot> is an ordinary element: it takes no slottables
  # and is never signaled.
  def test_a_foreign_slot_is_not_a_slot
    @sr.inner_html = "<svg><slot name='a'></slot></svg><math><slot name='a'></slot></math><slot name='a'></slot>"
    @host.append_child(@doc.create_element("i")).set_attribute("slot", "a")
    @win.scheduler.drain_microtasks
    html_slot = @sr.query_selector_all("slot").find { |s| s.is_a?(Dommy::HTMLSlotElement) }
    assert_equal 2, html_slot.assigned_nodes.length
    assert_equal html_slot, @host.query_selector("span").assigned_slot
  end

  # assignedSlot reads one slot, whatever the number of the tree's slots.
  def test_assigned_slot_of_text_and_elements
    text = @host.append_child(@doc.create_text_node("t"))
    assert_equal slot(""), text.assigned_slot
    assert_equal slot("a"), @host.query_selector("span").assigned_slot
  end
end

# A document with no window of its own still has slotchange: the window of the
# document that made it runs the microtask.
class TestSlotChangeWithoutWindow < Minitest::Test
  include DommyTestHelper

  def test_a_created_document_signals_through_its_creators_window
    win = make_window
    doc = win.document.implementation.create_html_document("")
    host = doc.body.append_child(doc.create_element("div"))
    sr = host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    slot = sr.append_child(doc.create_element("slot"))
    child = host.append_child(doc.create_element("p"))
    fired = false
    slot.add_event_listener("slotchange", proc { fired = true })
    slot.assign(child)
    win.scheduler.drain_microtasks
    assert fired
  end
end

# DOM "adopt" moves a host's shadow tree with it: the shadow root, its slots
# and their assignment work in the document the host went to.
class TestShadowTreeAdoption < Minitest::Test
  include DommyTestHelper

  def test_a_host_moved_to_another_document_keeps_its_shadow_tree
    win = make_window("<div id='h'><span>x</span></div>")
    doc = win.document
    host = doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<p><slot></slot></p>"
    slot = sr.query_selector("slot")
    span = host.query_selector("span")
    other = doc.implementation.create_html_document("")
    other.body.append_child(host)

    assert_same slot, span.assigned_slot
    assert_same other, slot.owner_document
    assert_same sr, other.__internal_shadow_root_for_host__(host.__dommy_backend_node__)
    reached = []
    slot.add_event_listener("ping", proc { reached << :slot })
    span.dispatch_event(Dommy::Event.new("ping", {"bubbles" => true}))
    assert_equal [:slot], reached
  end
end
