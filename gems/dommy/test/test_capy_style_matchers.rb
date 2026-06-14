# frozen_string_literal: true

require_relative "test_helper"
require "dommy/rspec/capy_style_matchers"

# Verifies the Capybara-style matchers by invoking matches? directly,
# so the rspec gem itself is not a hard dependency. The matcher
# protocol (matches?, failure_message, etc.) is what RSpec consumes.
class TestCapyStyleMatchers < Minitest::Test
  include DommyTestHelper
  include Dommy::RSpec::CapyStyleMatchers

  def setup
    @win = make_window(
      <<~HTML
        <article class="post">
          <h1>Welcome</h1>
          <p hidden>Hidden paragraph</p>
          <p style="display: none">Styled hidden</p>
          <ul>
            <li>One</li>
            <li>Two</li>
            <li>Three</li>
          </ul>
          <a href="/signup">Sign up</a>
          <a href="/login">Log in</a>
          <button type="submit">Submit</button>
          <input type="submit" value="Go">
          <input type="text" name="email" id="email-field" value="x@y.com">
          <label for="email-field">Email address</label>
          <textarea name="bio">hello</textarea>
        </article>
      HTML
    )
    @dom = @win.document
  end

  # --- have_selector / have_css ---------------------------------------

  def test_have_selector_finds_element
    assert(have_selector("button").matches?(@dom))
  end

  def test_have_selector_with_text
    assert(have_selector("h1", text: "Welcome").matches?(@dom))
    refute(have_selector("h1", text: "Goodbye").matches?(@dom))
  end

  def test_have_selector_with_exact_text
    assert(have_selector("h1", text: "Welcome", exact: true).matches?(@dom))
    refute(have_selector("h1", text: "Welc", exact: true).matches?(@dom))
  end

  def test_have_selector_with_count
    assert(have_selector("li", count: 3).matches?(@dom))
    refute(have_selector("li", count: 5).matches?(@dom))
  end

  def test_have_selector_with_count_range
    assert(have_selector("li", count: 1..5).matches?(@dom))
  end

  def test_have_css_is_alias
    assert(have_css("button").matches?(@dom))
  end

  def test_have_no_selector
    assert(have_no_selector(".missing").matches?(@dom))
    refute(have_no_selector("button").matches?(@dom))
  end

  # --- visibility -----------------------------------------------------

  def test_have_selector_ignores_hidden_elements_by_default
    # 2 <p> exist, but both are hidden by attribute / inline style
    refute(have_selector("p").matches?(@dom))
  end

  def test_have_selector_visible_all_includes_hidden
    matcher = have_selector("p", visible: :all)
    assert(matcher.matches?(@dom))
    assert_equal(2, matcher.instance_variable_get(:@matched).size)
  end

  def test_have_selector_visible_hidden_only_finds_hidden
    matcher = have_selector("p", visible: :hidden)
    assert(matcher.matches?(@dom))
    assert_equal(2, matcher.instance_variable_get(:@matched).size)
  end

  def test_visibility_filter_respects_ancestor_hidden_attribute
    dom = make_window("<section hidden><p>Inside hidden</p></section>").document
    refute(have_selector("p").matches?(dom))
    assert(have_selector("p", visible: :all).matches?(dom))
  end

  def test_visibility_filter_respects_inline_display_none_on_ancestor
    dom = make_window("<div style='display: none'><p>Inside</p></div>").document
    refute(have_selector("p").matches?(dom))
  end

  def test_visibility_filter_ignores_template_descendants
    dom = make_window("<template><p>Inside template</p></template>").document
    refute(have_selector("p").matches?(dom))
  end

  # --- have_content / have_text ---------------------------------------

  def test_have_content
    assert(have_content("Welcome").matches?(@dom))
    refute(have_content("Cancel").matches?(@dom))
  end

  def test_have_text_is_alias
    assert(have_text("Welcome").matches?(@dom))
  end

  def test_have_no_content
    assert(have_no_content("Cancel").matches?(@dom))
    refute(have_no_content("Welcome").matches?(@dom))
  end

  # --- have_link ------------------------------------------------------

  def test_have_link_by_text
    assert(have_link("Sign up").matches?(@dom))
    refute(have_link("Logout").matches?(@dom))
  end

  def test_have_link_by_href
    assert(have_link(href: "/signup").matches?(@dom))
    refute(have_link(href: "/missing").matches?(@dom))
  end

  def test_have_link_text_and_href
    assert(have_link("Sign up", href: "/signup").matches?(@dom))
    refute(have_link("Sign up", href: "/login").matches?(@dom))
  end

  def test_have_no_link
    assert(have_no_link("Logout").matches?(@dom))
  end

  # --- have_button ----------------------------------------------------

  def test_have_button_by_text
    assert(have_button("Submit").matches?(@dom))
    refute(have_button("Cancel").matches?(@dom))
  end

  def test_have_button_matches_input_submit_by_value
    assert(have_button("Go").matches?(@dom))
  end

  def test_have_button_by_type
    assert(have_button(type: "submit").matches?(@dom))
  end

  # --- have_field -----------------------------------------------------

  def test_have_field_by_name
    assert(have_field("email").matches?(@dom))
  end

  def test_have_field_by_id
    assert(have_field("email-field").matches?(@dom))
  end

  def test_have_field_by_label
    assert(have_field("Email address").matches?(@dom))
  end

  def test_have_field_with_value
    assert(have_field("email", with: "x@y.com").matches?(@dom))
    refute(have_field("email", with: "other@y.com").matches?(@dom))
  end

  def test_have_field_textarea
    assert(have_field("bio").matches?(@dom))
  end

  # --- wait option is ignored ----------------------------------------

  def test_wait_option_is_accepted_and_ignored
    # Should not raise; should behave identically with or without :wait
    assert(have_selector("h1", wait: 5).matches?(@dom))
  end

  # --- string subject (Capybara-style direct HTML input) -------------

  def test_have_selector_accepts_raw_html_string
    html = "<div><h1>Hello</h1></div>"
    assert(have_selector("h1").matches?(html))
    assert(have_selector("h1", text: "Hello").matches?(html))
  end

  def test_have_content_accepts_raw_html_string
    html = "<p>Welcome to our site</p>"
    assert(have_content("Welcome").matches?(html))
    refute(have_content("Goodbye").matches?(html))
  end

  def test_have_link_accepts_raw_html_string
    html = "<a href='/about'>About</a>"
    assert(have_link("About", href: "/about").matches?(html))
  end

  # --- failure_context decoration ------------------------------------

  def test_failure_context_appends_to_message
    Dommy::RSpec.failure_context = ->(subject) { "Context for #{subject.class}" }
    matcher = have_selector("h1.missing")
    refute(matcher.matches?(@dom))

    assert_includes(matcher.failure_message, "expected to find")
    assert_includes(matcher.failure_message, "Context for")
  ensure
    Dommy::RSpec.failure_context = nil
  end

  def test_failure_context_default_leaves_message_unchanged
    matcher = have_content("Goodbye")
    refute(matcher.matches?(@dom))

    # No context registered: the message is exactly the matcher's own, with no
    # appended blank-line-separated section.
    assert(matcher.failure_message.start_with?("expected text to include \"Goodbye\", got "))
    refute_includes(matcher.failure_message, "\n\n")
  end

  def test_failure_context_errors_do_not_mask_failure
    Dommy::RSpec.failure_context = ->(_subject) { raise "boom" }
    matcher = have_selector("h1.missing")
    refute(matcher.matches?(@dom))

    assert_includes(matcher.failure_message, "expected to find")
  ensure
    Dommy::RSpec.failure_context = nil
  end
end
