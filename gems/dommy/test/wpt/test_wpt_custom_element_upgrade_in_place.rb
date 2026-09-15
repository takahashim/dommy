# frozen_string_literal: true

require_relative "../test_helper"

# Upgrading an element happens once, and it is the element a script already
# holds that is upgraded. Upgrading an element that is already custom does
# nothing; and when an upgrade re-wraps a node, the new wrapper learns which one
# it replaced, so a JS-defined element can upgrade the reference a script holds
# in place instead of leaving it behind as a plain HTMLElement.
#
# Spec: https://html.spec.whatwg.org/multipage/custom-elements.html#concept-upgrade-an-element
# WPT:  custom-elements/CustomElementRegistry.html
class TestWPTCustomElementUpgradeInPlace < Minitest::Test
  include DommyTestHelper

  LOG = []

  class Probe < Dommy::HTMLElement
    def connected_callback
      LOG << [:connected, id]
    end

    def __internal_upgraded_from__(previous)
      LOG << [:upgraded_from, previous.class]
    end
  end

  def setup
    LOG.clear
    @win = make_window("<div id='p'></div>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
  end

  def test_the_new_wrapper_learns_which_one_it_replaced
    early = @doc.create_element("probe-el")
    early.id = "early"
    @p.append_child(early)
    @win.custom_elements.define("probe-el", Probe)

    assert_equal([[:upgraded_from, Dommy::HTMLElement], [:connected, "early"]], LOG)
  end

  def test_upgrading_an_element_that_is_already_custom_does_nothing
    @win.custom_elements.define("probe-el", Probe)
    el = @doc.create_element("probe-el")
    el.id = "once"
    @p.append_child(el)
    LOG.clear

    @win.custom_elements.upgrade(@p)
    assert_equal([], LOG)
    assert_same(el, @doc.get_element_by_id("once"))
  end
end
