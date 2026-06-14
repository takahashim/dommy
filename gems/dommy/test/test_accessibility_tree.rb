# frozen_string_literal: true

require_relative "test_helper"

# Internal::AccessibilityTree.build — DOM-to-a11y inclusion/flattening rules.
class TestAccessibilityTree < Minitest::Test
  include DommyTestHelper

  # The accessible nodes a document's body contributes (as plain hashes).
  def tree(html)
    Dommy::Internal::AccessibilityTree.build(make_window(html).document).to_h[:children] || []
  end

  def test_aria_hidden_subtree_excluded
    nodes = tree('<button>A</button><button aria-hidden="true">B</button>')
    assert_equal [{role: "button", name: "A"}], nodes
  end

  def test_display_none_excluded
    nodes = tree('<p>visible</p><p style="display:none">gone</p>')
    # A paragraph has no accessible name (not name-from-content); its text is a
    # child node. The display:none paragraph is excluded entirely.
    assert_equal [{role: "paragraph", children: [{role: :text, name: "visible"}]}], nodes
  end

  def test_presentational_role_promotes_children
    # role=presentation on the div drops it; the span is generic and collapses
    # too, leaving its text.
    assert_equal [{role: :text, name: "hi"}], tree('<div role="presentation"><span>hi</span></div>')
  end

  def test_generic_container_collapses
    nodes = tree('<div class="wrap"><button>Save <span>now</span></button></div>')
    assert_equal [{role: "button", name: "Save now"}], nodes
  end

  def test_name_from_content_keeps_roled_children
    nodes = tree('<button>Go <a href="/x">link</a></button>')
    assert_equal "button", nodes.first[:role]
    # The descendant text folds into the name; the link survives as a child.
    assert_equal [{role: "link", name: "link"}], nodes.first[:children]
  end

  def test_standalone_text_node_emitted
    nodes = tree('<main>Hello <a href="/x">x</a></main>')
    main = nodes.first
    assert_equal "main", main[:role]
    assert_equal [{role: :text, name: "Hello"}, {role: "link", name: "x"}], main[:children]
  end

  def test_heading_level_in_states
    assert_equal [{role: "heading", name: "Title", states: {level: 2}}], tree("<h2>Title</h2>")
  end

  def test_list_and_listitems
    nodes = tree("<ul><li>A</li><li>B</li></ul>")
    assert_equal "list", nodes.first[:role]
    roles = nodes.first[:children].map { |c| c[:role] }
    assert_equal %w[listitem listitem], roles
  end

  def test_lone_unscoped_th_folds_into_row
    # A single unscoped th in a single-row/single-cell table is not emitted as a
    # header cell; the row keeps its name (Chromium behavior).
    nodes = tree("<table><tr><th>X</th></tr></table>")
    row = nodes.first[:children].first[:children].first # table > rowgroup > row
    assert_equal({role: "row", name: "X"}, row)

    # A scoped th, or one with a sibling cell, stays a real header.
    scoped = tree('<table><tr><th scope="col">X</th></tr></table>')
    cell = scoped.first[:children].first[:children].first[:children].first
    assert_equal "columnheader", cell[:role]
  end

  def test_adjacent_text_coalesces_with_block_spacing
    # <summary> is block-level → its text is separated from the trailing text
    # by a space, and the two merge into one node.
    nodes = tree("<details open><summary>Settings</summary>Title</details>")
    assert_equal [{role: "group", children: [{role: :text, name: "Settings Title"}]}], nodes
  end

  def test_adjacent_inline_text_glues
    # Inline <label>s collapse and their promoted text glues with no space.
    nodes = tree("<label>Save</label><label>Save</label>")
    assert_equal [{role: :text, name: "SaveSave"}], nodes
  end
end
