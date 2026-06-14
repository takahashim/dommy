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

  def test_adjacent_text_is_coalesced
    # <summary> collapses to text "Settings"; the trailing "Title" text merges
    # with it into one text node under the details group.
    nodes = tree("<details open><summary>Settings</summary>Title</details>")
    assert_equal [{role: "group", children: [{role: :text, name: "Settings Title"}]}], nodes
  end
end
