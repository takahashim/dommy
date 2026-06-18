# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestUrl < Minitest::Test
  Url = Dommy::Rack::Url

  def test_ascii_url_is_unchanged
    url = "https://note.com/posts/1?q=a#frag"
    assert_same url, Url.encode_iri(url)
  end

  def test_percent_encodes_non_ascii_path_as_utf8
    assert_equal "https://note.com/hashtag/%E5%BF%9C%E6%8F%B4",
                 Url.encode_iri("https://note.com/hashtag/応援")
  end

  def test_encodes_a_relative_ref_whole
    assert_equal "/hashtag/%E5%BF%9C", Url.encode_iri("/hashtag/応")
  end

  def test_leaves_the_authority_untouched
    # Only the path is escaped; the host is left for IDNA, not byte-escaped.
    assert_equal "https://note.com/%E5%BF%9C", Url.encode_iri("https://note.com/応")
  end

  def test_is_idempotent_over_already_encoded_input
    once = Url.encode_iri("https://note.com/hashtag/応援")
    assert_equal once, Url.encode_iri(once)
  end

  def test_preserves_query_and_fragment_non_ascii
    assert_equal "https://note.com/s?q=%E7%8C%AB#%E7%8A%AC",
                 Url.encode_iri("https://note.com/s?q=猫#犬")
  end

  def test_result_is_parseable_by_stdlib_uri
    parsed = URI.parse(Url.encode_iri("https://note.com/hashtag/応援"))
    assert_equal "note.com", parsed.host
    assert_equal "/hashtag/%E5%BF%9C%E6%8F%B4", parsed.path
  end
end
