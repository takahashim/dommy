# frozen_string_literal: true

require_relative "test_helper"

# Engine-free golden test for the Ruby side of the wire protocol: it pins the
# exact tagged shapes Marshaller#wrap emits and that #unwrap / #dom_guard /
# #callback_result accept, so a change to an inner key or flag is caught without
# a JS engine. (The JS side's agreement is BridgeConformance's job.)
class TestJsMarshaller < Minitest::Test
  WT = Dommy::Js::WireTags
  B = Dommy::Bridge

  def setup
    # The bridge ref is only used to back HostCallback/HostEventListener/
    # HostNodeFilter wrappers; a plain object suffices for shape checks.
    @m = Dommy::Js::Marshaller.new(Object.new)
  end

  # ---- wrap (Ruby -> wire) ----

  def test_wrap_undefined
    assert_equal({WT::UNDEFINED => true}, @m.wrap(B::UNDEFINED))
  end

  def test_wrap_bytes_and_array_buffer
    assert_equal({WT::BYTES => [1, 2, 3]}, @m.wrap(B::Bytes.new([1, 2, 3])))
    # ArrayBuffer < Bytes, so it must be tagged ARRAY_BUFFER (checked first).
    assert_equal({WT::ARRAY_BUFFER => [4, 5]}, @m.wrap(B::ArrayBuffer.new([4, 5])))
  end

  def test_wrap_js_value_keeps_ref
    assert_equal({WT::JS_REF => 7}, @m.wrap(B::JSValue.new(7, "label")))
  end

  def test_wrap_bridgeable_object_becomes_handle
    obj = bridgeable_object
    wrapped = @m.wrap(obj)
    assert_equal [WT::HANDLE], wrapped.keys
    assert_kind_of Integer, wrapped[WT::HANDLE]
    assert_same obj, @m.host(wrapped[WT::HANDLE])
  end

  def test_wrap_plain_array_and_hash_recurse
    assert_equal [1, {WT::UNDEFINED => true}], @m.wrap([1, B::UNDEFINED])
    assert_equal({"a" => {WT::UNDEFINED => true}}, @m.wrap({"a" => B::UNDEFINED}))
  end

  def test_wrap_passes_scalars_through
    assert_equal 3, @m.wrap(3)
    assert_equal "x", @m.wrap("x")
    assert_nil @m.wrap(nil)
    assert_equal true, @m.wrap(true)
  end

  # ---- unwrap (wire -> Ruby) ----

  def test_unwrap_handle_resolves_registered_object
    obj = bridgeable_object
    handle = @m.register(obj)
    assert_same obj, @m.unwrap({WT::HANDLE => handle})
  end

  def test_unwrap_unknown_handle_is_nil
    assert_nil @m.unwrap({WT::HANDLE => 999_999})
  end

  def test_unwrap_callback_is_host_callback
    cb = @m.unwrap({WT::CALLBACK => 1})
    assert_kind_of Dommy::Js::HostCallback, cb
    # Memoized by id.
    assert_same cb, @m.unwrap({WT::CALLBACK => 1})
  end

  def test_unwrap_js_ref_variants
    assert_kind_of B::JSValue, @m.unwrap({WT::JS_REF => "r1"})
    assert_kind_of Dommy::Js::HostEventListener, @m.unwrap({WT::JS_REF => "r2", WT::HANDLE_EVENT => true})
    assert_kind_of Dommy::Js::HostNodeFilter, @m.unwrap({WT::JS_REF => "r3", WT::ACCEPT_NODE => true})
  end

  def test_unwrap_undefined_tag_and_bare_symbol
    assert_same B::UNDEFINED, @m.unwrap({WT::UNDEFINED => true})
    assert_same B::UNDEFINED, @m.unwrap(:undefined)
  end

  def test_unwrap_bytes
    bytes = @m.unwrap({WT::BYTES => [9, 8]})
    assert_kind_of B::Bytes, bytes
    assert_equal [9, 8], bytes.to_a
  end

  def test_unwrap_plain_hash_recurses
    assert_equal({"a" => B::UNDEFINED}, @m.unwrap({"a" => {WT::UNDEFINED => true}}))
  end

  # ---- dom_guard (Ruby exception -> wire) ----

  def test_dom_guard_passes_value_through
    assert_equal 42, @m.dom_guard { 42 }
  end

  def test_dom_guard_maps_dom_exception
    result = @m.dom_guard { raise Dommy::DOMException::NotFoundError, "nope" }
    assert_equal "NotFoundError", result[WT::EXCEPTION]["name"]
    assert_equal "nope", result[WT::EXCEPTION]["message"]
    assert result[WT::EXCEPTION].key?("code")
  end

  def test_dom_guard_maps_native_js_errors
    type_err = @m.dom_guard { raise B::TypeError, "bad" }
    assert_equal "TypeError", type_err[WT::EXCEPTION]["name"]
    assert_equal true, type_err[WT::EXCEPTION]["js_native"]

    range_err = @m.dom_guard { raise B::RangeError, "oor" }
    assert_equal "RangeError", range_err[WT::EXCEPTION]["name"]
    assert_equal true, range_err[WT::EXCEPTION]["js_native"]
  end

  def test_dom_guard_maps_thrown_value
    result = @m.dom_guard { raise B::ThrowValue.new("reason") }
    assert_equal "reason", result[WT::THROW]
  end

  # ---- callback_result ----

  def test_callback_result_normal_value
    assert_equal "ok", @m.callback_result("ok", false)
  end

  def test_callback_result_swallows_throw_by_default
    assert_nil @m.callback_result({WT::CALLBACK_THREW => {WT::UNDEFINED => true}}, false)
  end

  def test_callback_result_reraises_when_raising
    assert_raises(Dommy::Bridge::ThrowValue) do
      @m.callback_result({WT::CALLBACK_THREW => "boom"}, true)
    end
  end

  # ---- Ruby-side round-trip (unwrap ∘ wrap) ----

  def test_ruby_round_trip
    obj = bridgeable_object
    assert_same obj, @m.unwrap(@m.wrap(obj))                 # handle -> same object
    assert_same B::UNDEFINED, @m.unwrap(@m.wrap(B::UNDEFINED))
    assert_equal [1, 2], @m.unwrap(@m.wrap(B::Bytes.new([1, 2]))).to_a
    assert_equal({"k" => [1, 2]}, @m.unwrap(@m.wrap({"k" => [1, 2]})))
  end

  private

  def bridgeable_object
    obj = Object.new
    def obj.__js_get__(key) = key
    obj
  end
end
