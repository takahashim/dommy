# frozen_string_literal: true

require_relative "test_helper"

# Element#computed_description — the WAI-ARIA accessible description:
# aria-describedby / aria-description / title, with title not double-counted as
# both the name and the description.
class TestAccessibleDescription < Minitest::Test
  include DommyTestHelper

  def desc_of(html, selector)
    make_window(html).document.query_selector(selector).computed_description.gsub(/\s+/, " ").strip
  end

  def test_describedby_joins_referenced_text
    html = '<button aria-describedby="a b">Go</button><span id="a">save</span><span id="b">now</span>'
    assert_equal "save now", desc_of(html, "button")
  end

  def test_aria_description_attribute
    assert_equal "more info", desc_of('<button aria-description="more info">Go</button>', "button")
  end

  def test_title_is_description_when_name_comes_from_elsewhere
    # name is "Go" (content), so title is free to be the description.
    assert_equal "tooltip", desc_of('<button title="tooltip">Go</button>', "button")
  end

  def test_title_not_double_counted_when_it_is_the_name
    # No content / label: title becomes the accessible NAME, so there is no
    # description.
    html = '<input type="text" title="Email">'
    el = make_window(html).document.query_selector("input")
    assert_equal "Email", el.computed_label
    assert_equal "", el.computed_description
  end

  def test_describedby_wins_over_aria_description_and_title
    html = '<button aria-describedby="d" aria-description="attr" title="t">Go</button><span id="d">ref</span>'
    assert_equal "ref", desc_of(html, "button")
  end

  def test_no_description
    assert_equal "", desc_of("<button>Go</button>", "button")
  end
end
