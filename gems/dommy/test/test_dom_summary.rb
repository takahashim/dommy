# frozen_string_literal: true

require_relative "test_helper"

# DomSummary enumerates a scope's user-facing controls; Debug wraps a node over
# it; Locator uses it to enrich "not found" messages with the candidates that
# were present.
class TestDomSummary < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <main>
        <form action="/articles" method="post">
          <label for="title">Title</label>
          <input type="text" name="article[title]" id="title">
          <input type="hidden" name="token" value="x">
          <textarea name="article[body]"></textarea>
          <button type="submit">Create</button>
        </form>
        <a href="/articles">Back</a>
        <a href="/articles/1/edit">Edit</a>
      </main>
    HTML
    @dom = @win.document
  end

  def test_buttons
    buttons = Dommy::Interaction::DomSummary.buttons(@dom)
    assert_equal 1, buttons.size
    assert_equal "Create", buttons.first[:label]
    assert_equal "submit", buttons.first[:type]
    assert_equal "button[type=submit]", buttons.first[:selector]
  end

  def test_fields_skip_hidden_and_use_label
    fields = Dommy::Interaction::DomSummary.fields(@dom)
    names = fields.map { |f| f[:name] }
    assert_includes names, "article[title]"
    assert_includes names, "article[body]"
    refute_includes names, "token", "hidden inputs are excluded"

    title = fields.find { |f| f[:name] == "article[title]" }
    assert_equal "Title", title[:label]
  end

  def test_links
    links = Dommy::Interaction::DomSummary.links(@dom)
    assert_equal [["Back", "/articles"], ["Edit", "/articles/1/edit"]],
      links.map { |l| [l[:text], l[:href]] }
  end

  def test_forms
    form = Dommy::Interaction::DomSummary.forms(@dom).first
    assert_equal "/articles", form[:action]
    assert_equal "post", form[:method]
    assert_equal ["article[title]", "article[body]"], form[:fields]
  end

  def test_to_text_has_sections
    text = Dommy::Interaction::DomSummary.to_text(@dom)
    assert_match(/Forms:/, text)
    assert_match(/Buttons:/, text)
    assert_match(/"Create" button\[type=submit\]/, text)
    assert_match(/"Edit" -> \/articles\/1\/edit/, text)
  end

  def test_debug_facade
    debug = Dommy::Interaction::Debug.new(@dom)
    assert_equal 1, debug.buttons.size
    assert_equal 2, debug.links.size
    assert_includes debug.dom_summary, "Fields:"
    assert_includes debug.visible_text, "Create"
  end

  def test_scoping_to_an_element
    main = @dom.query_selector("main")
    assert_equal 1, Dommy::Interaction::DomSummary.buttons(main).size
  end
end

# The shared finder lists available candidates when a locator misses.
class TestLocatorAvailableMessages < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <form>
        <input name="email" aria-label="Email">
        <button type="submit">Save</button>
      </form>
    HTML
    @locator = Dommy::Interaction::Locator.new(@win.document)
  end

  def test_button_not_found_lists_available
    error = assert_raises(Dommy::Interaction::ElementNotFoundError) { @locator.find_button("Publish") }
    assert_includes error.message, 'no button matching "Publish"'
    assert_includes error.message, "Available buttons:"
    assert_includes error.message, '"Save" button[type=submit]'
  end

  def test_field_not_found_lists_available
    error = assert_raises(Dommy::Interaction::ElementNotFoundError) { @locator.find_field("Name") }
    assert_includes error.message, "Available fields:"
    assert_includes error.message, "Email"
  end

  def test_message_without_candidates_is_plain
    locator = Dommy::Interaction::Locator.new(make_window("<div></div>").document)
    error = assert_raises(Dommy::Interaction::ElementNotFoundError) { locator.find_button("X") }
    assert_equal 'no button matching "X"', error.message
  end
end
