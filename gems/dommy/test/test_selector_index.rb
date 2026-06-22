# frozen_string_literal: true

require_relative "test_helper"

# SelectorMatcher's document-scoped fast path uses a per-generation by-id/class/
# tag index (Internal::SelectorIndex). These tests pin that it returns exactly
# what the walk would — in document order, kept correct across mutations, and
# under the adaptive bypass.
class TestSelectorIndex < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="root" class="box">
        <a class="link" href="/a">A</a>
        <span class="link tag">B</span>
        <p>text</p>
        <a class="link" href="/b">C</a>
      </div>
    HTML
    @doc = @win.document
  end

  def test_class_query_returns_all_in_document_order
    links = @doc.query_selector_all(".link")
    assert_equal(3, links.length)
    assert_equal(%w[A B C], links.map(&:text_content))
  end

  def test_tag_query_via_index
    assert_equal(2, @doc.query_selector_all("a").length)
    assert_equal("text", @doc.query_selector("p").text_content)
  end

  def test_id_query_via_index
    assert_equal("root", @doc.query_selector("#root").get_attribute("id"))
    assert_equal(1, @doc.query_selector_all("#root").length)
  end

  def test_compound_uses_index_subject_then_full_match
    # `a.link` — the index gates by tag `a`, matches? checks the `.link` class.
    assert_equal(%w[A C], @doc.query_selector_all("a.link").map(&:text_content))
    # `.tag` only the span.
    assert_equal(%w[B], @doc.query_selector_all(".tag").map(&:text_content))
  end

  def test_index_reflects_an_appended_element
    assert_equal(3, @doc.query_selector_all(".link").length)
    a = @doc.create_element("a")
    a.set_attribute("class", "link")
    a.text_content = "D"
    @doc.get_element_by_id("root").append(a)
    # The mutation bumps the generation; the next query rebuilds the index.
    assert_equal(4, @doc.query_selector_all(".link").length)
  end

  def test_index_reflects_a_removed_element
    @doc.query_selector(".tag").remove
    assert_equal(2, @doc.query_selector_all(".link").length)
    assert_empty(@doc.query_selector_all(".tag"))
  end

  def test_index_reflects_a_class_attribute_change
    assert_equal(3, @doc.query_selector_all(".link").length)
    @doc.query_selector("p").set_attribute("class", "link")
    assert_equal(4, @doc.query_selector_all(".link").length)
  end

  # jQuery's `.find` is element-scoped (`el.querySelectorAll`); the index must
  # restrict candidates to the scope element's subtree, not the whole document.
  def test_element_scoped_query_only_returns_descendants_of_the_scope
    win = make_window(<<~HTML)
      <div id="a"><span class="x">A1</span><p class="x">A2</p></div>
      <div id="b"><span class="x">B1</span></div>
    HTML
    doc = win.document
    assert_equal(3, doc.query_selector_all(".x").length) # document-wide
    a = doc.get_element_by_id("a")
    b = doc.get_element_by_id("b")
    assert_equal(%w[A1 A2], a.query_selector_all(".x").map(&:text_content))
    assert_equal(%w[B1], b.query_selector_all(".x").map(&:text_content))
    assert_nil(b.query_selector(".not-there"))
  end

  def test_element_scope_excludes_the_scope_element_itself
    win = make_window(%(<div id="s" class="x"><span class="x">child</span></div>))
    doc = win.document
    s = doc.get_element_by_id("s")
    # querySelectorAll is descendant-only: the scope's own matching node is excluded.
    assert_equal(%w[child], s.query_selector_all(".x").map(&:text_content))
  end

  def test_element_scoped_query_survives_mutation
    win = make_window(%(<div id="s"><a class="x">1</a></div><a class="x">outside</a>))
    doc = win.document
    s = doc.get_element_by_id("s")
    assert_equal(1, s.query_selector_all(".x").length)
    n = doc.create_element("a")
    n.set_attribute("class", "x")
    s.append(n)
    assert_equal(2, s.query_selector_all(".x").length) # index rebuilt, scoped correctly
  end

  # The descendant-combinator short-circuit (any_ancestor? via the index) must
  # agree with the walk: a `.a .b` matches a `.b` iff it has a `.a` ancestor.
  def test_descendant_combinator_via_ancestor_index
    win = make_window(<<~HTML)
      <div class="outer">
        <div class="mid"><span class="leaf">in</span></div>
      </div>
      <span class="leaf">out</span>
    HTML
    doc = win.document
    assert_equal(%w[in], doc.query_selector_all(".outer .leaf").map(&:text_content))
    assert_equal(%w[in], doc.query_selector_all(".mid .leaf").map(&:text_content))
    assert_empty(doc.query_selector_all(".nope .leaf"))
    # both leaves match a bare descendant of body
    assert_equal(2, doc.query_selector_all("body .leaf").length)
    # element-scoped descendant
    outer = doc.query_selector(".outer")
    assert_equal(%w[in], outer.query_selector_all(".mid .leaf").map(&:text_content))
  end

  def test_descendant_short_circuit_only_for_exact_class_id
    # `.a.b .leaf` (compound with two classes) must NOT take the simple short-circuit
    # — it still has to verify both classes on the ancestor.
    win = make_window(%(<div class="a"><span class="leaf">x</span></div><div class="a b"><span class="leaf">y</span></div>))
    doc = win.document
    assert_equal(%w[y], doc.query_selector_all(".a.b .leaf").map(&:text_content))
  end

  # Hammer with a mutation between every query (the case that trips the adaptive
  # bypass) and confirm results stay correct throughout.
  def test_correct_under_mutation_between_every_query
    root = @doc.get_element_by_id("root")
    40.times do |i|
      root.set_attribute("data-n", i.to_s) # bump the generation each iteration
      assert_equal(3, @doc.query_selector_all(".link").length, "iteration #{i}")
      assert_equal(2, @doc.query_selector_all("a").length, "iteration #{i}")
    end
  end
end
