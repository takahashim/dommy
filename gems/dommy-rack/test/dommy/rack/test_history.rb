# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestHistory < Minitest::Test
  def setup
    @history = Dommy::Rack::History.new
  end

  def test_starts_empty
    assert_nil @history.current
    assert_nil @history.back
    assert_nil @history.forward
  end

  def test_push_sets_current
    @history.push("/a")
    assert_equal "/a", @history.current
  end

  def test_back_and_forward
    @history.push("/a")
    @history.push("/b")
    @history.push("/c")

    assert_equal "/b", @history.back.url
    assert_equal "/a", @history.back.url
    assert_nil @history.back # already at start
    assert_equal "/a", @history.current

    assert_equal "/b", @history.forward.url
    assert_equal "/c", @history.forward.url
    assert_nil @history.forward # already at end
  end

  def test_push_truncates_forward_entries
    @history.push("/a")
    @history.push("/b")
    @history.push("/c")
    @history.back # at /b
    @history.back # at /a

    @history.push("/d")
    assert_equal "/d", @history.current
    assert_equal %w[/a /d], @history.entries
    assert_nil @history.forward
  end
end
