# frozen_string_literal: true

require_relative "test_helper"

# Document-rooted querySelector(All) memoizes results within a DOM generation
# (NodeWrapperCache#query_cache). These tests pin the invalidation contract: a
# cached result must never outlive a mutation that changes what the selector
# matches — structural, attribute, or :focus state.
class TestQueryCache < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <div id="root">
          <span class="item">A</span>
          <span class="item">B</span>
        </div>
      HTML
    )
    @doc = @win.document
  end

  def test_repeated_query_returns_fresh_but_equal_node_lists
    first = @doc.query_selector_all(".item")
    second = @doc.query_selector_all(".item")
    assert_equal(2, first.length)
    assert_equal(first.to_a, second.to_a)
    # querySelectorAll returns a fresh static NodeList each call — the cache
    # reuses the match set, not the list object.
    refute_same(first, second)
  end

  def test_appending_a_matching_element_invalidates
    assert_equal(2, @doc.query_selector_all(".item").length)

    span = @doc.create_element("span")
    span.set_attribute("class", "item")
    @doc.get_element_by_id("root").append(span)

    assert_equal(3, @doc.query_selector_all(".item").length)
  end

  def test_removing_a_matching_element_invalidates
    assert_equal(2, @doc.query_selector_all(".item").length)

    @doc.query_selector(".item").remove

    assert_equal(1, @doc.query_selector_all(".item").length)
  end

  def test_attribute_change_invalidates
    assert_equal(2, @doc.query_selector_all(".item").length)
    assert_equal(0, @doc.query_selector_all(".item.active").length)

    @doc.query_selector(".item").set_attribute("class", "item active")

    assert_equal(1, @doc.query_selector_all(".item.active").length)
  end

  def test_query_first_caches_a_nil_match_then_revalidates
    assert_nil(@doc.query_selector(".missing"))
    # Second call is served from cache (still nil) without re-walking.
    assert_nil(@doc.query_selector(".missing"))

    span = @doc.create_element("span")
    span.set_attribute("class", "missing")
    @doc.get_element_by_id("root").append(span)

    refute_nil(@doc.query_selector(".missing"))
  end

  def test_focus_change_invalidates_focus_pseudo
    @doc.body.inner_html = "<input id='f'>"
    input = @doc.get_element_by_id("f")
    assert_equal(0, @doc.query_selector_all(":focus").length)

    input.focus

    assert_equal(1, @doc.query_selector_all(":focus").length)
    assert_same(input, @doc.query_selector(":focus"))
  end
end

# Element-scoped querySelector(All) (jQuery `$(el).find`) is memoized separately
# (Document#__internal_scoped_query_*). Same invalidation contract: a cached
# scoped result must not outlive a mutation.
class TestScopedQueryCache < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="a"><span class="x">A1</span><p class="x">A2</p></div>
      <div id="b"><span class="x">B1</span></div>
    HTML
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
  end

  def test_repeated_scoped_query_is_fresh_but_equal
    first = @a.query_selector_all(".x")
    second = @a.query_selector_all(".x")
    assert_equal(%w[A1 A2], first.map(&:text_content))
    assert_equal(first.to_a, second.to_a)
    refute_same(first, second) # a fresh static NodeList each call
  end

  def test_scope_is_respected_on_cache_hit
    # Two scopes, same selector — must not cross-contaminate.
    assert_equal(%w[A1 A2], @a.query_selector_all(".x").map(&:text_content))
    assert_equal(%w[B1], @b.query_selector_all(".x").map(&:text_content))
    assert_equal(%w[A1 A2], @a.query_selector_all(".x").map(&:text_content)) # still A's, from cache
  end

  def test_scoped_cache_invalidates_on_mutation
    assert_equal(2, @a.query_selector_all(".x").length)
    n = @doc.create_element("span")
    n.set_attribute("class", "x")
    @a.append(n)
    assert_equal(3, @a.query_selector_all(".x").length)
  end

  def test_scoped_query_first_caches_nil_then_revalidates
    assert_nil(@b.query_selector(".missing"))
    assert_nil(@b.query_selector(".missing"))
    m = @doc.create_element("i")
    m.set_attribute("class", "missing")
    @b.append(m)
    refute_nil(@b.query_selector(".missing"))
  end
end
