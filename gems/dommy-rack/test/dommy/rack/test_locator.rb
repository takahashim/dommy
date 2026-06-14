# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestLocator < Minitest::Test
  def locator_for(html)
    Dommy::Rack::Locator.new(Dommy.parse(html).document)
  end

  def test_find_field_by_id
    loc = locator_for('<input id="email" name="e">')
    assert_equal "email", loc.find_field("email").get_attribute("id")
  end

  def test_find_field_by_name
    loc = locator_for('<input name="post[title]">')
    assert_equal "post[title]", loc.find_field("post[title]").get_attribute("name")
  end

  def test_find_field_by_label_text
    loc = locator_for('<label for="e">Email</label><input id="e" name="e">')
    assert_equal "e", loc.find_field("Email").get_attribute("id")
  end

  def test_find_field_by_placeholder_and_aria_label
    loc = locator_for('<input name="q" placeholder="Search"><input name="c" aria-label="City">')
    assert_equal "q", loc.find_field("Search").get_attribute("name")
    assert_equal "c", loc.find_field("City").get_attribute("name")
  end

  def test_find_field_not_found
    loc = locator_for("<input name='a'>")
    assert_raises(Dommy::Rack::ElementNotFoundError) { loc.find_field("missing") }
  end

  def test_find_field_ambiguous
    loc = locator_for('<input name="dup"><input placeholder="dup">')
    assert_raises(Dommy::Rack::AmbiguousElementError) { loc.find_field("dup") }
  end

  def test_not_found_message_lists_available_candidates
    loc = locator_for('<input name="email" aria-label="Email"><button type="submit">Save</button>')
    error = assert_raises(Dommy::Rack::ElementNotFoundError) { loc.find_button("Publish") }
    assert_includes error.message, 'no button matching "Publish"'
    assert_includes error.message, '"Save" button[type=submit]'
  end

  def test_find_link_by_text_and_href
    loc = locator_for('<a href="/x">Go</a>')
    assert_equal "/x", loc.find_link("Go").get_attribute("href")
    assert_equal "Go", loc.find_link("/x").text_content
  end

  def test_find_button_by_text
    loc = locator_for("<form><button>Create</button></form>")
    assert_equal "Create", loc.find_button("Create").text_content
  end

  def test_find_option_by_text_then_value
    document = Dommy.parse('<select><option value="r">Red</option><option value="g">Green</option></select>').document
    loc = Dommy::Rack::Locator.new(document)
    select_el = document.query_selector("select")
    assert_equal "Red", loc.find_option(select_el, "Red").text_content
    assert_equal "Green", loc.find_option(select_el, "g").text_content
  end

  def test_form_for_via_closest
    document = Dommy.parse('<form id="f"><button id="b">Go</button></form>').document
    loc = Dommy::Rack::Locator.new(document)
    button = document.get_element_by_id("b")
    assert_equal "f", loc.form_for(button).get_attribute("id")
  end

  def test_form_for_via_form_attribute
    document = Dommy.parse('<form id="f"></form><button id="b" form="f">Go</button>').document
    loc = Dommy::Rack::Locator.new(document)
    button = document.get_element_by_id("b")
    assert_equal "f", loc.form_for(button).get_attribute("id")
  end
end
