# frozen_string_literal: true

require "test_helper"
require "dommy/rails/rspec"
require "dommy/rails/minitest/assertions"

# AriaSnapshotMatching (subset + regex) and the match_aria_snapshot matcher /
# assert_aria_snapshot assertion.
class TestAriaSnapshotMatching < Minitest::Test
  include Dommy::Rails::Minitest::Assertions

  Matchers = Class.new { include Dommy::Rails::RSpec::Matchers }

  PAGE = <<~HTML
    <header><h1>Articles</h1></header>
    <main>
      <ul>
        <li><a href="/1">First</a></li>
        <li><a href="/2">Second</a></li>
      </ul>
      <button>Save</button>
    </main>
  HTML

  def matching = @matching ||= Dommy::Rails::AriaSnapshotMatching

  # Structure is matched from the root (like Playwright); extra sibling nodes —
  # here `main`'s list — are allowed, but the nesting must hold.
  def test_subset_match_ignores_extra_nodes
    actual = Dommy.parse(PAGE).document.aria_snapshot
    expected = <<~SNAP
      - banner:
        - heading "Articles" [level=1]
      - main:
        - button "Save"
    SNAP
    assert matching.matches?(actual, expected)
  end

  def test_nested_subset_match
    actual = Dommy.parse(PAGE).document.aria_snapshot
    expected = <<~SNAP
      - main:
        - list:
          - listitem:
            - link "Second"
    SNAP
    assert matching.matches?(actual, expected)
  end

  def test_regex_name
    actual = Dommy.parse(PAGE).document.aria_snapshot
    assert matching.matches?(actual, %(- banner:\n  - heading /Art\\w+/ [level=1]\n))
  end

  def test_mismatch
    actual = Dommy.parse(PAGE).document.aria_snapshot
    refute matching.matches?(actual, %(- main:\n  - button "Delete"\n))
    refute matching.matches?(actual, %(- banner:\n  - heading "Articles" [level=2]\n))
  end

  def test_rspec_matcher_passes_on_html_string
    matcher = Matchers.new.match_aria_snapshot(%(- main:\n  - button "Save"\n))
    assert matcher.matches?(PAGE)
  end

  def test_rspec_matcher_failure_message
    matcher = Matchers.new.match_aria_snapshot(%(- main:\n  - button "Nope"\n))
    refute matcher.matches?(PAGE)
    assert_includes matcher.failure_message, "expected aria snapshot to match"
    assert_includes matcher.failure_message, "Nope"
  end

  def test_minitest_assertion
    assert_aria_snapshot(%(- banner:\n  - heading "Articles" [level=1]\n), PAGE)
  end
end
