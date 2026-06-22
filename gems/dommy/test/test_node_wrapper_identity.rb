# frozen_string_literal: true

require_relative "test_helper"

# NodeWrapperCache keys live wrappers by a backend identity (Makiri's lxb node
# pointer, Nokogiri's object_id). Both backends can hand a freed *transient*
# node's identity to a brand-new node — e.g. a throwaway fragment parsed by
# `Parser.fragment` for `DocumentFragment#cloneNode`, once the original is GC'd.
# When that happens the cache must NOT return the stale wrapper of the wrong
# kind; it has to notice the mismatch (via nodeType) and rebuild. Regression
# for a data-each clone resolving to a cached TextNode instead of a Fragment.
class TestNodeWrapperIdentity < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @cache = @doc.instance_variable_get(:@node_wrapper_cache)
  end

  # Force every node to the SAME identity key so a later wrap() sees the prior
  # wrapper as a (simulated) recycled-identity collision.
  def with_pinned_identity_key(key)
    cache = @cache
    cache.define_singleton_method(:identity_key) { |_node| key }
    yield
  ensure
    cache.singleton_class.send(:remove_method, :identity_key)
  end

  def test_recycled_identity_does_not_return_wrong_kind_wrapper
    tpl = @doc.create_element("template")
    tpl.inner_html = "<li>row</li>"

    with_pinned_identity_key(42) do
      # First occupy the shared key with a TextNode wrapper.
      text_wrapper = @doc.wrap_node(@doc.backend_doc.fragment("hello").children.first)
      assert_instance_of(Dommy::TextNode, text_wrapper)

      # A fragment node now lands on the same (pinned) key. The stale TextNode
      # must not be handed back — the clone has to come through as a Fragment.
      clone = tpl.content.__js_call__("cloneNode", [true])
      assert_instance_of(Dommy::Fragment, clone)
      assert_equal(1, clone.child_element_count)
      assert_equal("row", clone.first_element_child.text_content)
    end
  end

  def test_same_kind_wrapper_is_still_reused
    # The validation must not defeat normal caching: the SAME live node wraps to
    # the SAME Ruby object across repeated traversals (DOM identity contract).
    host = @doc.get_element_by_id("host")
    again = @doc.get_element_by_id("host")
    assert_same(host, again)
  end
end
