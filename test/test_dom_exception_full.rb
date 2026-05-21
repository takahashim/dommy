# frozen_string_literal: true

require_relative "test_helper"

# Extended DOMException coverage — constructor forms, JS-bridge access,
# to_s format, dynamic-name handling, and all subclasses.
class TestDOMExceptionConstructor < Minitest::Test
  def test_no_args_constructor
    e = Dommy::DOMException.new
    assert_equal("Error", e.name)
    assert_equal(0, e.code)
    assert_equal("", e.message)
  end

  def test_message_only_constructor
    e = Dommy::DOMException::NotFoundError.new("missing")
    assert_equal("NotFoundError", e.name)
    assert_equal("missing", e.message)
    assert_equal(8, e.code)
  end

  def test_message_and_name_constructor_sets_name
    e = Dommy::DOMException.new("bad", "SyntaxError")
    assert_equal("SyntaxError", e.name)
    assert_equal("bad", e.message)
  end

  def test_unknown_dynamic_name_keeps_code_zero
    e = Dommy::DOMException.new("???", "MysteriousError")
    assert_equal("MysteriousError", e.name)
    assert_equal(0, e.code)
  end

  def test_known_dynamic_name_recovers_legacy_code
    # On the base class only, LEGACY_CODES maps known spec names to
    # their numeric code so `new DOMException("x", "SyntaxError").code`
    # returns 12 as JS callers expect.
    e = Dommy::DOMException.new("x", "SyntaxError")
    assert_equal(12, e.code)
  end

  def test_explicit_name_overrides_class_name_for_subclass
    # An explicit name argument on a subclass changes `name` but the
    # legacy `code` continues to reflect the actual subclass.
    e = Dommy::DOMException::SyntaxError.new("msg", "NotFoundError")
    assert_equal("NotFoundError", e.name)
    # SyntaxError's code stays
    assert_equal(12, e.code)
  end

  def test_to_s_format
    e = Dommy::DOMException::IndexSizeError.new("oob")
    assert_equal("IndexSizeError: oob", e.to_s)
  end

  def test_to_s_empty_message
    e = Dommy::DOMException::IndexSizeError.new
    assert_equal("IndexSizeError: ", e.to_s)
  end
end

class TestDOMExceptionJsBridge < Minitest::Test
  def test_js_get_name
    e = Dommy::DOMException::NotFoundError.new("x")
    assert_equal("NotFoundError", e.__js_get__("name"))
  end

  def test_js_get_code
    e = Dommy::DOMException::NotFoundError.new("x")
    assert_equal(8, e.__js_get__("code"))
  end

  def test_js_get_message
    e = Dommy::DOMException::NotFoundError.new("text")
    assert_equal("text", e.__js_get__("message"))
  end

  def test_js_get_unknown_key_returns_nil
    e = Dommy::DOMException.new
    assert_nil(e.__js_get__("whatever"))
  end
end

class TestDOMExceptionAllSubclasses < Minitest::Test
  # Verify every subclass instance has a valid name + code per the
  # WebIDL spec table.
  EXPECTED = {
    "IndexSizeError" => 1,
    "HierarchyRequestError" => 3,
    "WrongDocumentError" => 4,
    "InvalidCharacterError" => 5,
    "NoModificationAllowedError" => 7,
    "NotFoundError" => 8,
    "NotSupportedError" => 9,
    "InUseAttributeError" => 10,
    "InvalidStateError" => 11,
    "SyntaxError" => 12,
    "InvalidModificationError" => 13,
    "NamespaceError" => 14,
    "InvalidAccessError" => 15,
    "TypeMismatchError" => 17,
    "SecurityError" => 18,
    "NetworkError" => 19,
    "AbortError" => 20,
    "URLMismatchError" => 21,
    "QuotaExceededError" => 22,
    "TimeoutError" => 23,
    "InvalidNodeTypeError" => 24,
    "DataCloneError" => 25,
    "EncodingError" => 0,
    "NotReadableError" => 0,
    "UnknownError" => 0,
    "ConstraintError" => 0,
    "DataError" => 0,
    "TransactionInactiveError" => 0,
    "ReadOnlyError" => 0,
    "VersionError" => 0,
    "OperationError" => 0,
    "NotAllowedError" => 0
  }.freeze

  EXPECTED.each do |name, code|
    define_method("test_subclass_#{name}_metadata") do
      klass = Dommy::DOMException.const_get(name)
      instance = klass.new
      assert_equal name, instance.name, "#{name} name"
      assert_equal code, instance.code, "#{name} code"
      assert klass < Dommy::DOMException, "#{name} should inherit from DOMException"
    end
  end
end

class TestDOMExceptionRescueSemantics < Minitest::Test
  def test_rescue_by_base_catches_subclass
    raised = false
    begin
      raise Dommy::DOMException::NotFoundError, "x"
    rescue Dommy::DOMException => e
      raised = e
    end

    refute_equal(false, raised)
    assert_equal("NotFoundError", raised.name)
  end

  def test_rescue_by_standard_error_also_catches
    rescued = false
    begin
      raise Dommy::DOMException::SyntaxError, "x"
    rescue StandardError
      rescued = true
    end

    assert(rescued)
  end

  def test_distinct_subclass_rescue
    rescued = nil
    begin
      raise Dommy::DOMException::NotFoundError, "missing"
    rescue Dommy::DOMException::SyntaxError
      rescued = :syntax
    rescue Dommy::DOMException::NotFoundError
      rescued = :notfound
    end

    assert_equal(:notfound, rescued)
  end
end
