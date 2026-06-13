# frozen_string_literal: true

require_relative "test_helper"

# HTML activation behavior for checkbox / radio inputs: click() toggles/checks,
# fires trusted input+change, restores on a canceled click, and a radio's
# checkedness is exclusive within its group.
class TestInputActivation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def input(html)
    @doc.body.inner_html = html
    @doc.query_selector("input")
  end

  def test_click_toggles_checkbox_and_fires_trusted_events
    cb = input("<input type=checkbox>")
    events = []
    %w[click input change].each do |type|
      cb.add_event_listener(type, proc { |e| events << [type, e.__js_get__("isTrusted")] })
    end
    cb.click

    assert(cb.checked, "checkbox toggled on")
    # click is script-initiated (untrusted); input/change are UA-generated.
    assert_equal([["click", false], ["input", true], ["change", true]], events)
  end

  def test_canceled_click_restores_checkbox
    cb = input("<input type=checkbox>")
    cb.add_event_listener("click", proc { |e| e.__js_call__("preventDefault", []) })
    cb.click

    refute(cb.checked, "checkedness restored after preventDefault")
  end

  def test_disabled_checkbox_has_no_activation
    cb = input("<input type=checkbox disabled>")
    fired = false
    cb.add_event_listener("input", proc { |_e| fired = true })
    cb.click

    refute(cb.checked)
    refute(fired, "no input event for a disabled checkbox")
  end

  def test_clicking_radio_unchecks_the_group
    @doc.body.inner_html = <<~HTML
      <input type=radio name=g id=a>
      <input type=radio name=g id=b>
      <input type=radio name=h id=c>
    HTML
    a = @doc.get_element_by_id("a")
    b = @doc.get_element_by_id("b")
    c = @doc.get_element_by_id("c")

    a.click
    assert(a.checked)
    b.click
    assert(b.checked)
    refute(a.checked, "the other radio in group g is unchecked")
    refute(c.checked, "a radio in a different group is unaffected")
  end

  def test_checkbox_indeterminate_property_and_clear_on_activation
    cb = input("<input type=checkbox>")
    cb.indeterminate = true
    assert(cb.indeterminate)
    cb.click
    refute(cb.indeterminate, "pre-click activation clears indeterminate")
  end
end
