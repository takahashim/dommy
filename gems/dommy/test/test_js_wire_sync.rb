# frozen_string_literal: true

require_relative "test_helper"

# Engine-free drift guard for the Ruby<->JS bridge: the WireTags constants and
# the host-function ABI registered by HostBridge must stay mirrored in
# host_runtime.js (the JS half). This is a cheap tripwire — it catches a tag /
# host-function renamed on only one side. It does NOT prove the shapes or
# behavior agree; that is BridgeConformance's job (run by the engine gems).
class TestJsWireSync < Minitest::Test
  RUNTIME_JS = Dommy::Js::HostBridge::HOST_RUNTIME_JS

  # Tags the JS half legitimately never emits, so they need not appear in
  # host_runtime.js. JS_LABEL is optional metadata the Ruby side *reads* off a
  # js_ref (for JSValue#to_s) but the JS side does not currently attach — see
  # Marshaller#unwrap, where a missing label is just nil.
  JS_OPTIONAL_TAGS = %w[__rb_js_label].freeze

  # Every WireTags tag value (except the JS-optional ones) must appear in
  # host_runtime.js (dehydrate/rehydrate mirror the same string literals).
  def test_wire_tags_are_mirrored_in_host_runtime_js
    Dommy::Js::WireTags.constants.each do |const|
      tag = Dommy::Js::WireTags.const_get(const)
      next unless tag.is_a?(String)
      next if JS_OPTIONAL_TAGS.include?(tag)

      assert_includes RUNTIME_JS, tag,
        "WireTags::#{const} (#{tag.inspect}) is missing from host_runtime.js — update the JS half in lockstep"
    end
  end

  # Every __rb_* host function HostBridge registers must be called from
  # host_runtime.js (and the JS half must not reference a host function the
  # bridge never registers).
  def test_host_function_abi_is_mirrored
    registered = registered_host_functions
    refute_empty registered, "expected HostBridge to register host functions"

    registered.each do |name|
      assert_includes RUNTIME_JS, name,
        "host function #{name.inspect} is registered by HostBridge but not referenced in host_runtime.js"
    end

    referenced_host_calls.each do |name|
      assert_includes registered, name,
        "host_runtime.js calls #{name.inspect} but HostBridge does not register it"
    end
  end

  private

  # The host-function names HostBridge registers, captured by booting it over a
  # backend that only records define_host_function (no engine needed).
  def registered_host_functions
    backend = RecordingBackend.new
    Dommy::Js::HostBridge.new(backend)
    backend.host_functions
  end

  # __rb_* identifiers host_runtime.js invokes as host functions (the
  # `callHost("__rb_...")` / direct-call sites). Excludes the WireTags data keys,
  # which are matched separately above.
  def referenced_host_calls
    tags = Dommy::Js::WireTags.constants.map { |c| Dommy::Js::WireTags.const_get(c) }.grep(String)
    RUNTIME_JS.scan(/__rb_[a-z_]+/).uniq.reject { |name| tags.include?(name) }
  end

  # Records the host functions a HostBridge registers; no-ops the rest of the
  # backend contract so construction completes without a JS engine.
  class RecordingBackend
    attr_reader :host_functions

    def initialize
      @host_functions = []
    end

    def define_host_function(name, &_block)
      @host_functions << name
    end

    def eval(_js) = nil
    def call_js(*) = nil
    def run_bundle(*) = nil
  end
end
