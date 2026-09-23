# frozen_string_literal: true

module Dommy
  # `Dommy::Bridge` — the protocol every JS host speaks to Dommy, and the
  # vocabulary the DOM answers it in.
  #
  # THE RULE, because it has drifted before: what is true of ANY host belongs
  # here; what is true of the host we happen to ship belongs in `Dommy::Js`.
  # So the sentinels, the value types that cross the boundary, the exceptions
  # a spec mandates and the wire tags are Bridge's, while the engine ABI, the
  # marshaller that reads those tags and the QuickJS-facing runtime are Js's.
  #
  # This namespace is NOT optional or embedder-only, whatever an older version
  # of this comment claimed: `Bridge::UNDEFINED` and `Bridge::Methods` are
  # spoken by most of the DOM classes in this gem. A backend gem (dommy-js-
  # quickjs, a future wasm one) depends on Bridge; nothing in the DOM depends
  # on Js.
  #
  # The protocol contract:
  #   - `__js_get__(name)` reads a JS-style property by string name
  #   - `__js_set__(name, value)` writes one
  #   - `__js_call__(method, args)` invokes a method with positional
  #     args (Array)
  #   - `__js_new__(args)` invokes the value as a JS constructor
  #
  # The pieces are one file each, by what they are — see the requires below.
  module Bridge; end
end

require_relative "bridge/sentinels"
require_relative "bridge/values"
require_relative "bridge/errors"
require_relative "bridge/constructor"
require_relative "bridge/wire_tags"
