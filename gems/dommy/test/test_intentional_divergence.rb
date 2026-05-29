# frozen_string_literal: true

require_relative "test_helper"

# Tests in this file describe places where Dommy *intentionally*
# differs from the WHATWG DOM spec / WPT expectations. They are NOT
# bugs — each represents a design choice made for Ruby ergonomics or
# embedder compatibility. If you change Dommy to align with spec,
# delete the test here and (typically) add an equivalent one to a
# `test/wpt/` file.
#
# Adding a new entry? Include a short paragraph: WHAT differs, WHAT
# spec says, WHY Dommy diverges, and (if relevant) how a consumer can
# get spec-aligned behavior.

class TestIntentionalDivergence_NodeListIsArray < Minitest::Test
  include DommyTestHelper

  # WHAT differs:
  #   `assert(list.is_a?(Array))` is true for Dommy NodeList, but
  #   `Array.isArray(nodelist)` is false in real browsers.
  #
  # WHAT spec says:
  #   WebIDL declares NodeList as a distinct interface that is
  #   iterable but NOT an Array. Browsers (and deno-dom) hide the
  #   internal array storage behind a proxy/wrapper so identity-
  #   checks like `Array.isArray` return false.
  #
  # WHY Dommy diverges:
  #   Ruby callers benefit enormously from `.map` / `.select` /
  #   `.first(n)` / `.zip` / pattern-match on Array. Forcing them to
  #   call `.to_a` first would make every consumer awkward without
  #   matching any real Ruby idiom. The Array spec surface that
  #   matters (length, [i], each) is also exactly what the DOM
  #   NodeList provides, so subclassing is the natural fit.
  #
  # How to get spec-aligned behavior:
  #   If a consumer must verify "not an Array", check against
  #   `Dommy::NodeList` directly instead of `Array`.
  def test_node_list_IS_array_sub
    win = make_window("<a></a><a></a>")
    assert_kind_of(Array, win.document.query_selector_all("a"))
  end

  def test_node_list_is_recognizably_a_nodelist
    win = make_window("<a></a>")
    assert_kind_of(Dommy::NodeList, win.document.query_selector_all("a"))
  end
end

class TestIntentionalDivergence_DOMExceptionInheritsStandardError < Minitest::Test
  # WHAT differs:
  #   `Dommy::DOMException < StandardError`, so a bare `rescue => e`
  #   catches every DOM exception. JS DOMException inherits Error
  #   (and is catchable by a `catch` block, which is the JS analogue).
  #
  # WHY Dommy diverges:
  #   Ruby's exception hierarchy treats StandardError as "ordinary
  #   recoverable errors", which is the right family for "this DOM
  #   call refused the operation". Inheriting from Exception directly
  #   would put DOMException alongside SystemExit / SignalException,
  #   which is wrong.
  def test_rescue_StandardError_catches_DOMException
    rescued = nil
    begin
      raise Dommy::DOMException::NotFoundError, "x"
    rescue StandardError => e
      rescued = e
    end

    assert_kind_of(Dommy::DOMException, rescued)
  end
end

class TestIntentionalDivergence_ForEachBlockArity < Minitest::Test
  include DommyTestHelper

  # WHAT differs:
  #   `nodelist.for_each` (spec name: `forEach`) yields the (value,
  #   index, list) triple via Ruby block-arity instead of a single
  #   callback argument. Spec JS form:
  #     list.forEach((value, key, listObj) => { ... });
  #   Dommy form:
  #     list.for_each { |value, index, list_obj| ... }
  #
  # WHY Dommy diverges:
  #   Block syntax is the idiomatic Ruby way to iterate. The block
  #   signature still matches the spec's (value, key, listObj) order,
  #   so JS callers porting code can copy the parameter list
  #   verbatim — only the surrounding `(...) => {}` / `do ... end`
  #   syntax changes.
  def test_for_each_yields_value_index_list_triple
    win = make_window("<a id='x'></a><a id='y'></a>")
    seen = []
    win.document.query_selector_all("a").for_each do |value, index, list|
      seen << [value.id, index, list.length]
    end

    assert_equal([["x", 0, 2], ["y", 1, 2]], seen)
  end
end
