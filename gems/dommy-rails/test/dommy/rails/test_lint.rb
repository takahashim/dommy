require "test_helper"

class TestLint < Minitest::Test
  include Dommy::TestHelpers

  def test_duplicate_ids
    html = '<div id="comment"></div><div id="comment"></div><div id="unique"></div>'
    doc = parse_html(html)
    duplicates = Dommy::Rails::Lint.duplicate_ids(doc)
    assert_equal ["comment"], duplicates
  end

  def test_no_duplicate_ids
    html = '<div id="a"></div><div id="b"></div>'
    doc = parse_html(html)
    duplicates = Dommy::Rails::Lint.duplicate_ids(doc)
    assert_empty duplicates
  end

  def test_invalid_aria_references
    html = '<div aria-labelledby="missing"></div>'
    doc = parse_html(html)
    issues = Dommy::Rails::Lint.invalid_aria_references(doc)
    assert_equal 1, issues.size
    assert_equal "missing", issues.first[:id]
  end

  def test_empty_links
    html = '<a href="/empty"></a><a href="/label" aria-label="Label"></a><a href="/text">Text</a>'
    doc = parse_html(html)
    issues = Dommy::Rails::Lint.empty_links(doc)
    assert_equal 1, issues.size
    assert_equal "/empty", issues.first.get_attribute("href")
  end

  def test_nested_interactive_elements
    html = '<button><a href="/nested">Nested</a></button><a href="/ok">OK</a>'
    doc = parse_html(html)
    issues = Dommy::Rails::Lint.nested_interactive_elements(doc)
    assert_equal 1, issues.size
    assert_equal "A", issues.first[:element].tag_name
    assert_equal "BUTTON", issues.first[:ancestor].tag_name
  end
end
