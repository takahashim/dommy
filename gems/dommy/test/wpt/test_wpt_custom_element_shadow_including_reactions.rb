# frozen_string_literal: true

require_relative "../test_helper"

# Custom element reactions reach into shadow trees. Inserting or removing a host
# connects or disconnects the custom elements in its shadow tree, and define()
# and customElements.upgrade() upgrade the elements in shadow trees — each in
# shadow-including tree order: an element, then the shadow tree it hosts, then
# its children. Chrome 149 does the same.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-insert
#       https://dom.spec.whatwg.org/#concept-node-remove
#       https://html.spec.whatwg.org/multipage/custom-elements.html#dom-customelementregistry-define
# WPT:  custom-elements/CustomElementRegistry.html
class TestWPTCustomElementShadowIncludingReactions < Minitest::Test
  include DommyTestHelper

  LOG = []

  class Probe < Dommy::HTMLElement
    def connected_callback
      LOG << [id, :connected]
    end

    def disconnected_callback
      LOG << [id, :disconnected]
    end
  end

  # Its connectedCallback attaches a shadow tree holding an already-defined
  # custom element.
  class AttachingHost < Probe
    def connected_callback
      super
      return if __internal_shadow_root__

      inner = document.create_element("probe-el")
      inner.id = "inner"
      attach_shadow({ "mode" => "open" }).append_child(inner)
    end
  end

  # Upgraded by define(), its connectedCallback fills a new shadow tree with an
  # element of its own name.
  class NestingHost < Probe
    def connected_callback
      super
      return unless id == "outer" && __internal_shadow_root__.nil?

      attach_shadow({ "mode" => "open" }).inner_html = "<nesting-el id='nested'></nesting-el>"
    end
  end

  def setup
    LOG.clear
    @win = make_window("<div id='p'></div>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
  end

  def probe(id, tag: "probe-el")
    el = @doc.create_element(tag)
    el.id = id
    el
  end

  def logged
    LOG.clear
    yield
    LOG.dup
  end

  def test_inserting_and_removing_a_host_reaches_its_shadow_tree
    @win.custom_elements.define("probe-el", Probe)
    host = probe("host")
    host.attach_shadow({ "mode" => "open" }).append_child(probe("in-shadow"))
    host.append_child(probe("child"))

    assert_equal([["host", :connected], ["in-shadow", :connected], ["child", :connected]],
                 logged { @p.append_child(host) })
    assert_equal([["host", :disconnected], ["in-shadow", :disconnected], ["child", :disconnected]],
                 logged { host.remove })
  end

  # The fixture of CustomElementRegistry.html's "must upgrade elements in the
  # shadow-including tree order".
  def test_define_upgrades_in_shadow_including_tree_order
    container = @doc.create_element("div")
    shadow_host = @doc.create_element("div")
    shadow = shadow_host.attach_shadow({ "mode" => "closed" })
    container.append_child(probe("before"))
    container.append_child(shadow_host)
    container.append_child(probe("after"))
    shadow_host.append_child(probe("child-of-host"))
    shadow.append_child(probe("in-shadow"))
    custom_host = probe("custom-host")
    shadow.append_child(custom_host)
    custom_host.attach_shadow({ "mode" => "closed" }).append_child(probe("in-nested-shadow"))
    @doc.body.append_child(container)

    order = logged { @win.custom_elements.define("probe-el", Probe) }.map(&:first)
    assert_equal(%w[before in-shadow custom-host in-nested-shadow child-of-host after], order)
  end

  def test_an_upgraded_host_keeps_its_shadow_root
    host = probe("host")
    shadow = host.attach_shadow({ "mode" => "open" })
    @p.append_child(host)
    @win.custom_elements.define("probe-el", Probe)

    upgraded = @doc.get_element_by_id("host")
    assert_kind_of(Probe, upgraded)
    assert_same(shadow, upgraded.shadow_root)
    assert_raises(Dommy::DOMException::NotSupportedError) { upgraded.attach_shadow({ "mode" => "open" }) }
  end

  # Chrome 149 and Firefox 155 connect the inner element once: its own insertion
  # does, and the walk that connected the host does not see the tree the callback
  # attached.
  def test_a_shadow_tree_attached_by_a_connected_callback_is_not_walked_again
    @win.custom_elements.define("probe-el", Probe)
    @win.custom_elements.define("attaching-el", AttachingHost)
    host = probe("host", tag: "attaching-el")

    assert_equal([["host", :connected], ["inner", :connected]], logged { @p.append_child(host) })
  end

  def test_define_does_not_upgrade_the_tree_an_upgraded_callback_creates_twice
    @p.inner_html = "<nesting-el id='outer'></nesting-el>"

    assert_equal([["outer", :connected], ["nested", :connected]],
                 logged { @win.custom_elements.define("nesting-el", NestingHost) })
  end

  def test_upgrade_reaches_into_shadow_trees_of_a_detached_subtree
    host = @doc.create_element("div")
    shadow = host.attach_shadow({ "mode" => "open" })
    shadow.append_child(probe("in-shadow"))
    @win.custom_elements.define("probe-el", Probe)

    assert_equal([], logged { @win.custom_elements.upgrade(host) })
    assert_kind_of(Probe, shadow.first_child)
  end
end
