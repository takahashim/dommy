# frozen_string_literal: true

require_relative "../test_helper"

# WPT: html/semantics/interactive-elements/the-details-element/name-attribute.html
# A non-empty `name` puts a details element in an exclusive accordion group with
# the others that share it in the same tree — at most one may be open.
class TestWPTDetailsNameGroups < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @container = @doc.create_element("div")
    @doc.body.append_child(@container)
  end

  def states(root = @container)
    root.children.to_a.map(&:open)
  end

  def fill(html, root = @container)
    root.inner_html = html
    root.children.to_a
  end

  def test_opening_one_member_closes_the_others
    first, second = fill("<details name='a'></details><details name='a'></details>")
    first.open = true
    assert_equal([true, false], states)
    second.open = true
    assert_equal([false, true], states)
    second.open = false
    assert_equal([false, false], states)
  end

  def test_reopening_the_open_member_changes_nothing
    first, = fill("<details name='a'></details><details name='a'></details>")
    first.open = true
    first.open = true
    assert_equal([true, false], states)
  end

  # The parser can produce several open members; the first in tree order is the
  # one that stays open, whatever order the attributes were written in.
  def test_a_parsed_group_settles_on_its_first_open_member
    fill("<details name='a' open></details><details name='a' open></details><details open name='a'></details>")
    assert_equal([true, false, false], states)
  end

  def test_an_element_inserted_into_a_settled_group_is_the_one_that_closes
    fill("<details name='a' open></details><details name='a'></details>")
    late = @doc.create_element("details")
    late.set_attribute("name", "a")
    late.open = true
    @container.append_child(late)
    refute(late.open)
    assert_equal([true, false, false], states)
  end

  # Even when it lands first in tree order — the incumbent wins, not the earlier
  # sibling.
  def test_insertion_at_the_front_of_a_group_still_yields
    first, = fill("<details name='a' open></details><details name='a'></details>")
    late = @doc.create_element("details")
    late.set_attribute("name", "a")
    late.open = true
    @container.insert_before(late, first)
    assert_equal([false, true, false], states)
  end

  # Renaming into a group is arriving there: the member already open keeps its
  # state and the newcomer closes.
  def test_renaming_into_a_group_closes_the_element_that_moved
    e0, _e1, e2 = fill("<details name='a' open></details><details name='a'></details><details name='b' open></details>")
    e2.set_attribute("name", "a")
    assert_equal([true, false, false], states)
    e0.set_attribute("name", "c")
    e2.open = true
    assert_equal([true, false, true], states)
    e0.set_attribute("name", "a")
    assert_equal([false, false, true], states)
  end

  def test_an_empty_or_missing_name_makes_no_group
    elements = fill("<details></details><details></details><details name></details>" \
                    "<details name></details><details name=''></details><details name=''></details>")
    elements.each { |element| element.open = true }
    assert_equal([true] * 6, states)
  end

  def test_groups_are_per_name
    a1, b1, a2, b2 = fill("<details name='a' open></details><details name='b' open></details>" \
                          "<details name='a'></details><details name='b'></details>")
    a2.open = true
    assert_equal([false, true, true, false], states)
    b2.open = true
    assert_equal([false, false, true, true], states)
    assert(a2.open)
    refute(a1.open)
    refute(b1.open)
    assert(b2.open)
  end

  # Groups are scoped to a tree, so a shadow tree's group is its own.
  def test_a_shadow_tree_has_its_own_groups
    host = @doc.create_element("x-host")
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: "open")
    outer = fill("<details name='a' open></details>")
    inner = fill("<details name='a' open></details>", root)
    inner[0].open = true
    assert(outer[0].open, "the light-tree member is in a different group")
    assert(inner[0].open)
  end

  def test_exclusivity_works_in_a_detached_tree
    detached = @doc.create_element("div")
    first, second = fill("<details name='a'></details><details name='a'></details>", detached)
    first.open = true
    assert_equal([true, false], [first.open, second.open])
    second.open = true
    assert_equal([false, true], [first.open, second.open])
  end
end

# WPT: html/semantics/interactive-elements/the-details-element/toggleEvent.html
class TestWPTDetailsToggleEvent < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @seen = []
  end

  def watch(element, label = nil)
    element.add_event_listener("toggle") do |e|
      @seen << [label || element.get_attribute("id"), e.__js_get__("oldState"), e.__js_get__("newState")]
    end
    element
  end

  def settle
    @win.scheduler.advance_time(1)
  end

  def details(open: false)
    element = @doc.create_element("details")
    element.set_attribute("open", "") if open
    @doc.body.append_child(element)
    element
  end

  def test_opening_queues_one_trusted_toggle_event
    element = watch(details, "d")
    seen = nil
    element.add_event_listener("toggle") { |e| seen = e }
    element.open = true
    assert_empty(@seen, "the event is queued, not fired synchronously")
    settle
    assert_equal([["d", "closed", "open"]], @seen)
    assert(seen.__js_get__("isTrusted"))
    refute(seen.__js_get__("bubbles"))
    refute(seen.__js_get__("cancelable"))
  end

  # Rapid changes coalesce: one event, reporting the state before the first
  # change and after the last.
  def test_opening_then_closing_fires_a_single_event
    element = watch(details, "d")
    element.open = true
    element.open = false
    settle
    assert_equal([["d", "closed", "closed"]], @seen)
  end

  def test_setting_the_state_it_already_has_fires_nothing
    element = details(open: true)
    settle # let the event it owed for being opened go by first
    watch(element, "d")
    element.open = true
    settle
    assert_empty(@seen)
  end

  # The parser sets `open` while building the element, so nothing queued its
  # event — the insertion steps owe it one.
  def test_a_details_the_parser_opened_still_gets_its_event
    host = @doc.create_element("div")
    @doc.body.append_child(host)
    host.inner_html = "<details id='p' open></details>"
    watch(host.query_selector("#p"))
    settle
    assert_equal([["p", "closed", "open"]], @seen)
  end

  def test_a_document_parsed_with_an_open_details_gets_one_too
    parser = Dommy::DOMParser.new(@win)
    doc = parser.parse_from_string("<details id='p' open></details>", "text/html")
    element = doc.query_selector("#p")
    element.add_event_listener("toggle") { |e| @seen << ["p", e.__js_get__("oldState"), e.__js_get__("newState")] }
    settle
    assert_equal([["p", "closed", "open"]], @seen)
  end

  # A change while an event is still queued cancels it and queues a fresh one at
  # the back, so a group's events arrive in the order it settled.
  def test_the_group_reports_in_the_order_it_settled
    host = @doc.create_element("div")
    @doc.body.append_child(host)
    host.inner_html = "<details id='e0' name='a' open></details><details id='e1' name='a'></details>"
    e0, e1 = host.children.to_a
    settle # e0 owes an event for the parser having opened it
    watch(e0)
    watch(e1)
    e1.open = true
    settle
    assert_equal([["e1", "closed", "open"], ["e0", "open", "closed"]], @seen)
  end

  # A change while the event is still queued cancels it: the surviving event
  # reports the state before the first change and after the last.
  def test_a_change_while_the_event_is_queued_coalesces_into_it
    host = @doc.create_element("div")
    @doc.body.append_child(host)
    host.inner_html = "<details id='e0' name='a' open></details><details id='e1' name='a'></details>"
    e0, e1 = host.children.to_a
    watch(e0)
    watch(e1)
    e1.open = true
    settle
    assert_equal([["e1", "closed", "open"], ["e0", "closed", "closed"]], @seen)
  end
end
