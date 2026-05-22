# frozen_string_literal: true

require "nokogiri"
require "set"

require_relative "dommy/version"
require_relative "dommy/dom_exception"
require_relative "dommy/node"
require_relative "dommy/html_collection"
require_relative "dommy/event"
require_relative "dommy/scheduler"
require_relative "dommy/observer"
require_relative "dommy/promise"
require_relative "dommy/blob"
require_relative "dommy/data_transfer"
require_relative "dommy/crypto"
require_relative "dommy/text_codec"
require_relative "dommy/observers"
require_relative "dommy/range"
require_relative "dommy/animation"
require_relative "dommy/bridge"
require_relative "dommy/storage"
require_relative "dommy/fetch"
require_relative "dommy/router"
require_relative "dommy/navigator"
require_relative "dommy/parser"
require_relative "dommy/attr"
require_relative "dommy/world"
require_relative "dommy/document"
require_relative "dommy/element"
require_relative "dommy/internal/reflected_attributes"
require_relative "dommy/html_elements"
require_relative "dommy/svg_elements"
require_relative "dommy/shadow_root"
require_relative "dommy/custom_elements"
require_relative "dommy/tree_walker"
require_relative "dommy/url"
require_relative "dommy/form_data"
require_relative "dommy/dom_parser"
require_relative "dommy/css"

module Dommy
  # Parse an HTML string and return a fresh `Window`.
  #
  # When the input starts with `<!doctype` or `<html>`, it is parsed as
  # a full HTML document (preserving <head>, <title>, etc.). Otherwise
  # the input is treated as a body fragment and inserted into a fresh
  # document's <body>.
  #
  # The Window has no host (standalone CRuby usage); embedders that need
  # bridge callbacks (e.g. a wasm host) pass a host instead.
  def self.parse(html)
    s = html.to_s
    if s.match?(/\A\s*(<!doctype|<html\b)/i)
      Window.new(nil, nokogiri_doc: Nokogiri::HTML5(s))
    else
      window = Window.new
      window.document.body.inner_html = s
      window
    end
  end

  # Build a fresh, empty Window (no host). Equivalent to opening a
  # blank document.
  def self.new_window
    Window.new
  end

  # `structuredClone(value)` — deep clone for plain Ruby values and
  # DOM nodes (via `cloneNode(true)`). Mirrors the JS structured-clone
  # algorithm for the subset we support:
  #
  #   - primitives (String / Numeric / Boolean / nil)         → copied
  #   - Array / Hash / Set                                    → deep-cloned
  #   - DOM nodes (anything responding to `clone_node`)       → deep-cloned
  #   - cyclic structures                                     → preserved
  #   - Proc / Method / Class / Module / IO                   → DataCloneError
  #
  # Symbols are passed through unchanged (Ruby has no `Symbol` clone
  # concept; JS treats Symbols as DataCloneError, but Ruby code uses
  # them as hash keys so this is the pragmatic choice).
  def self.structured_clone(value, memo = {})
    return memo[value.object_id] if memo.key?(value.object_id)

    case value
    when nil, true, false, Numeric, Symbol
      value
    when String
      value.dup
    when Array
      arr = []
      memo[value.object_id] = arr
      value.each { |v| arr << structured_clone(v, memo) }
      arr
    when Hash
      h = {}
      memo[value.object_id] = h
      value.each { |k, v| h[structured_clone(k, memo)] = structured_clone(v, memo) }
      h
    when Set
      s = Set.new
      memo[value.object_id] = s
      value.each { |v| s << structured_clone(v, memo) }
      s
    when Time
      value.dup
    when Regexp
      value.dup
    when Proc, Method, UnboundMethod, IO, Class, Module
      raise DOMException::DataCloneError, "#{value.class} cannot be cloned"
    else
      if value.respond_to?(:clone_node)
        value.clone_node(true)
      else
        # Fallback: rely on the object's own `dup` (which handles
        # custom classes the user might pass through).
        value.dup
      end
    end
  end
end

# JS-style global alias for symmetry with `window.structuredClone(...)`.
def Dommy.structuredClone(value)
  structured_clone(value)
end
