# frozen_string_literal: true

module Dommy
  # `DOMException` — base class for DOM-spec errors. Subclasses match
  # the well-known names from the WebIDL spec; each carries the
  # legacy `code` integer (0 for names introduced after the legacy
  # code table) and the canonical `name`.
  #
  # Use:
  #   raise Dommy::DOMException::IndexSizeError, "index 5 out of range"
  #   rescue Dommy::DOMException => e
  #     e.name      # => "IndexSizeError"
  #     e.code      # => 1
  #     e.message   # => "index 5 out of range"
  #     e.to_s      # => "IndexSizeError: index 5 out of range"
  #
  # The 2-arg form mirrors JS `new DOMException(message, name)`:
  #   Dommy::DOMException.new("bad input", "SyntaxError")
  # which constructs a base DOMException carrying the supplied name —
  # useful when the name is dynamic and you don't have a subclass.
  #
  # Inherits from StandardError so generic `rescue => e` catches them.
  class DOMException < StandardError
    NAME = "Error"
    CODE = 0

    # Legacy-name → numeric-code map. Used only by the 2-arg
    # `new DOMException(msg, name)` form when the supplied name doesn't
    # match the current subclass. Subclass-direct construction reads
    # `self.class::CODE` and ignores this map.
    LEGACY_CODES = {
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
      "DataCloneError" => 25
    }.freeze

    def initialize(message = "", name = nil)
      @__message = message.to_s
      super(@__message)
      @explicit_name = name&.to_s
    end

    def message
      @__message.to_s
    end

    def name
      @explicit_name || self.class::NAME
    end

    # When constructed on the base class with a dynamic name, derive
    # the code from LEGACY_CODES (0 for unknown). When constructed via
    # a subclass, always return that subclass's CODE so the legacy
    # number is preserved even if the caller passed a different name.
    def code
      return self.class::CODE if self.class != DOMException || @explicit_name.nil?

      LEGACY_CODES[@explicit_name] || 0
    end

    # JS exposes `e.name`, `e.code`, `e.message`.
    def __js_get__(key)
      case key
      when "name"
        name
      when "code"
        code
      when "message"
        message
      else
        Bridge::ABSENT
      end
    end

    def to_s
      "#{name}: #{@__message}"
    end

    class IndexSizeError < self
      NAME = "IndexSizeError"
      CODE = 1
    end

    class HierarchyRequestError < self
      NAME = "HierarchyRequestError"
      CODE = 3
    end

    class WrongDocumentError < self
      NAME = "WrongDocumentError"
      CODE = 4
    end

    class InvalidCharacterError < self
      NAME = "InvalidCharacterError"
      CODE = 5
    end

    class NoModificationAllowedError < self
      NAME = "NoModificationAllowedError"
      CODE = 7
    end

    class NotFoundError < self
      NAME = "NotFoundError"
      CODE = 8
    end

    class NotSupportedError < self
      NAME = "NotSupportedError"
      CODE = 9
    end

    class InUseAttributeError < self
      NAME = "InUseAttributeError"
      CODE = 10
    end

    class InvalidStateError < self
      NAME = "InvalidStateError"
      CODE = 11
    end

    class SyntaxError < self
      NAME = "SyntaxError"
      CODE = 12
    end

    class InvalidModificationError < self
      NAME = "InvalidModificationError"
      CODE = 13
    end

    class NamespaceError < self
      NAME = "NamespaceError"
      CODE = 14
    end

    class InvalidAccessError < self
      NAME = "InvalidAccessError"
      CODE = 15
    end

    class TypeMismatchError < self
      NAME = "TypeMismatchError"
      CODE = 17
    end

    class SecurityError < self
      NAME = "SecurityError"
      CODE = 18
    end

    class NetworkError < self
      NAME = "NetworkError"
      CODE = 19
    end

    class AbortError < self
      NAME = "AbortError"
      CODE = 20
    end

    class URLMismatchError < self
      NAME = "URLMismatchError"
      CODE = 21
    end

    class QuotaExceededError < self
      NAME = "QuotaExceededError"
      CODE = 22
    end

    class TimeoutError < self
      NAME = "TimeoutError"
      CODE = 23
    end

    class InvalidNodeTypeError < self
      NAME = "InvalidNodeTypeError"
      CODE = 24
    end

    class DataCloneError < self
      NAME = "DataCloneError"
      CODE = 25
    end

    # Modern names without legacy codes (code is 0). Listed here so
    # `rescue Dommy::DOMException::EncodingError` works.
    class EncodingError < self
      NAME = "EncodingError"
      CODE = 0
    end

    class NotReadableError < self
      NAME = "NotReadableError"
      CODE = 0
    end

    class UnknownError < self
      NAME = "UnknownError"
      CODE = 0
    end

    class ConstraintError < self
      NAME = "ConstraintError"
      CODE = 0
    end

    class DataError < self
      NAME = "DataError"
      CODE = 0
    end

    class TransactionInactiveError < self
      NAME = "TransactionInactiveError"
      CODE = 0
    end

    class ReadOnlyError < self
      NAME = "ReadOnlyError"
      CODE = 0
    end

    class VersionError < self
      NAME = "VersionError"
      CODE = 0
    end

    class OperationError < self
      NAME = "OperationError"
      CODE = 0
    end

    class NotAllowedError < self
      NAME = "NotAllowedError"
      CODE = 0
    end
  end
end
