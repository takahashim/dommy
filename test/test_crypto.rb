# frozen_string_literal: true

require_relative "test_helper"

class TestCrypto < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @crypto = Dommy::Crypto.new
  end

  def test_random_uuid_returns_v4_uuid
    uuid = @crypto.random_uuid
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/, uuid)
  end

  def test_random_uuid_is_unique
    uuids = Array.new(5) { @crypto.random_uuid }
    assert_equal(5, uuids.uniq.length)
  end

  def test_camel_case_alias
    assert_match(/\A[0-9a-f]{8}-/, @crypto.randomUUID)
  end

  def test_get_random_values_fills_array
    buf = Array.new(16, 0)
    result = @crypto.get_random_values(buf)
    assert_same(buf, result)
    # Extremely unlikely to be all zero
    refute(buf.all?(0))
    assert(buf.all? { |b| b.between?(0, 255) })
  end

  def test_js_bridge
    assert_match(/\A[0-9a-f]{8}-/, @crypto.__js_call__("randomUUID", []))

    buf = Array.new(8, 0)
    @crypto.__js_call__("getRandomValues", [buf])
    refute(buf.all?(0))
  end

  def test_window_exposes_crypto
    assert_kind_of(Dommy::Crypto, @win.__js_get__("crypto"))
  end
end
