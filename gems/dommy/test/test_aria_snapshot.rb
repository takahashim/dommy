# frozen_string_literal: true

require_relative "test_helper"

# Document/Element#aria_snapshot — Playwright-compatible ARIA snapshot text.
class TestAriaSnapshot < Minitest::Test
  include DommyTestHelper

  def snap(html)
    make_window(html).document.aria_snapshot
  end

  def test_landmarks_heading_and_list
    html = <<~HTML
      <header><h1>Welcome</h1></header>
      <nav aria-label="Main"><ul><li><a href="/a">A</a></li><li><a href="/b">B</a></li></ul></nav>
    HTML
    expected = <<~SNAP
      - banner:
        - heading "Welcome" [level=1]
      - navigation "Main":
        - list:
          - listitem:
            - link "A"
          - listitem:
            - link "B"
    SNAP
    assert_equal expected, snap(html)
  end

  def test_form_with_states
    html = <<~HTML
      <form aria-label="Signup">
        <label>Email <input type="email" required></label>
        <input type="checkbox" checked>
        <button>Submit</button>
      </form>
    HTML
    # A wrapping <label>'s text both names its control AND appears as a
    # standalone text node — matching Playwright (the label is not suppressed).
    # readonly / required are not serialized (Playwright emits neither).
    expected = <<~SNAP
      - form "Signup":
        - text: "Email"
        - textbox "Email"
        - checkbox [checked]
        - button "Submit"
    SNAP
    assert_equal expected, snap(html)
  end

  def test_generic_collapse_and_button_text_fold
    assert_equal %(- button "Save now"\n),
      snap('<div class="wrap"><button>Save <span>now</span></button></div>')
  end

  def test_standalone_text_node
    assert_equal %(- main:\n  - text: "Hello"\n  - link "x"\n),
      snap('<main>Hello <a href="/x">x</a></main>')
  end

  def test_document_snapshot_equals_body_element_snapshot
    win = make_window("<main><h2>Title</h2></main>")
    assert_equal win.document.aria_snapshot, win.document.body.aria_snapshot
  end

  def test_range_and_number_show_value
    # A range slider always shows its value (default = midpoint); a number
    # spinbutton only when non-empty. ARIA aria-valuenow shows nothing.
    assert_equal %(- slider "x":\n  - text: "3"\n), snap('<input type="range" min="0" max="10" value="3" aria-label="x">')
    assert_equal %(- slider "x":\n  - text: "50"\n), snap('<input type="range" aria-label="x">')
    assert_equal %(- spinbutton "x":\n  - text: "2"\n), snap('<input type="number" value="2" aria-label="x">')
    assert_equal %(- spinbutton "x"\n), snap('<input type="number" aria-label="x">')
    assert_equal %(- slider "x"\n), snap('<div role="slider" aria-valuenow="5" aria-label="x"></div>')
    # color is a textbox showing its value (default "#000000").
    assert_equal %(- textbox "x":\n  - text: "#000000"\n), snap('<input type="color" aria-label="x">')
  end

  def test_to_h_programmatic
    tree = make_window("<h2>Title</h2>").document.accessibility_tree
    assert_equal [{role: "heading", name: "Title", states: {level: 2}}], tree.to_h[:children]
  end
end
