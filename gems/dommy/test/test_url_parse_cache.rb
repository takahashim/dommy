# frozen_string_literal: true

require_relative "test_helper"

# A parse of strings is remembered (Internal::UrlParser::PARSES), and each
# caller gets a record of its own: what one changes through the URL API's
# setters, the next parse of the same strings does not see.
class TestUrlParseCache < Minitest::Test
  PARSER = Dommy::Internal::UrlParser

  def setup
    PARSER::PARSES.clear
  end

  def test_a_repeated_parse_is_remembered
    PARSER.parse("/a/b?q#f", "http://example.test/x")
    assert_equal 1, PARSER::PARSES.size

    PARSER.parse("/a/b?q#f", "http://example.test/x")
    assert_equal 1, PARSER::PARSES.size
  end

  def test_a_setter_does_not_reach_the_remembered_parse
    url = Dommy::URL.new("http://example.test/a/b?q#f")
    url.pathname = "/x/y/z"
    url.search = "?changed"
    url.hostname = "other.test"

    assert_equal "http://example.test/a/b?q#f", Dommy::URL.new("http://example.test/a/b?q#f").href
  end

  def test_a_record_is_the_callers_to_change
    first = PARSER.parse("http://example.test/a/b")
    first.path << "c"
    first.query = "q"

    second = PARSER.parse("http://example.test/a/b")
    assert_equal %w[a b], second.path
    assert_nil second.query
    refute_same first, second
  end

  # A copy of a record owns its path; a frozen record is frozen through.
  def test_a_record_copy_owns_its_path
    record = PARSER.parse("http://example.test/a")
    copy = record.dup
    copy.path << "b"
    assert_equal %w[a], record.path

    record.freeze
    assert record.scheme.frozen?
    assert record.path.frozen?
    refute record.dup.path.frozen?
  end

  def test_a_failure_is_remembered_and_raised_again
    2.times { assert_raises(PARSER::Failure) { PARSER.parse("http://[") } }
    assert_equal 1, PARSER::PARSES.size
    2.times { assert_nil Dommy::URL.parse("http://[") }
  end

  def test_the_base_and_encoding_are_part_of_the_parse
    assert_equal "http://a.test/x", PARSER.serialize(PARSER.parse("x", "http://a.test/"))
    assert_equal "http://b.test/x", PARSER.serialize(PARSER.parse("x", "http://b.test/"))

    utf8 = PARSER.serialize(PARSER.parse("?é", "http://a.test/"))
    latin1 = PARSER.serialize(PARSER.parse("?é", "http://a.test/", encoding: "windows-1252"))
    refute_equal utf8, latin1
  end

  def test_a_long_input_is_not_remembered
    data = "data:text/plain,#{"x" * 4096}"
    assert_equal data, PARSER.serialize(PARSER.parse(data))
    assert_equal 0, PARSER::PARSES.size
  end

  def test_a_mutated_input_string_does_not_change_the_remembered_key
    input = +"http://example.test/a"
    PARSER.parse(input)
    input << "/b"
    assert_equal "http://example.test/a", PARSER.serialize(PARSER.parse("http://example.test/a"))
  end
end
