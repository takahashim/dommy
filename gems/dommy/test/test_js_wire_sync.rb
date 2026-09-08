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

  # host_runtime.js must tag a top-level `undefined` crossing to Ruby itself
  # (dehydrateTop), rather than relying on the backend to marshal a bare JS
  # `undefined` to a sentinel — that is what keeps the protocol engine-neutral
  # (V8/mini_racer cannot tell undefined from null). Guards against reverting the
  # return/set sites to a bare `dehydrate(...)`.
  def test_undefined_is_tagged_engine_neutrally
    assert_includes RUNTIME_JS, "function dehydrateTop",
      "host_runtime.js must define dehydrateTop so undefined crosses as a tag on every engine"
    assert_operator RUNTIME_JS.scan(/dehydrateTop\(/).size, :>=, 4,
      "dehydrateTop should tag undefined at the call-arg, callback-return, and property-set sites"
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

# The event handler CONTENT attributes are enumerated once, in host_runtime.js —
# it gates the runtime `setAttribute("on*")` path on them, and the boot-time
# inline-handler wiring reads the same sets rather than carrying a second copy.
# An `on*` attribute outside them names no event handler and must stay inert.
# WPT: html/webappapis/scripting/events/event-handler-non-content-document-idl-attributes.html
class TestEventHandlerContentAttributes < Minitest::Test
  RUNTIME_JS = Dommy::Js::HostBridge::HOST_RUNTIME_JS
  BOOT_JS = Dommy::Js::ScriptBooter::WIRE_INLINE_HANDLERS_JS

  def names_in(constant)
    body = RUNTIME_JS[/const #{constant} = new Set\(\[(.*?)\]\);/m, 1]
    refute_nil(body, "#{constant} is missing from host_runtime.js")
    body.scan(/"([^"]+)"/).flatten
  end

  def element_handlers = names_in("ELEMENT_HANDLER_ATTRIBUTES")
  def reflected_handlers = names_in("WINDOW_REFLECTED_HANDLERS")

  # These are event handler IDL attributes of Document (and Element for the
  # pointer-lock pair); none of them is a content attribute on any element.
  DOCUMENT_ONLY = %w[onreadystatechange onvisibilitychange onpointerlockchange onpointerlockerror].freeze

  def test_the_document_only_handlers_are_in_neither_set
    DOCUMENT_ONLY.each do |name|
      refute_includes(element_handlers, name)
      refute_includes(reflected_handlers, name)
    end
  end

  def test_the_element_set_covers_the_handlers_elements_actually_have
    %w[
      onclick oninput onsubmit ontoggle onwheel onscrollend onslotchange onsecuritypolicyviolation
      onpointerdown onpointerrawupdate ongotpointercapture ontouchstart onanimationstart
      onfocusin onfocusout onselectstart oncommand oncontextlost
    ].each { |name| assert_includes(element_handlers, name) }
  end

  # The Window handlers are content attributes on body and frameset only, so
  # they belong to the reflected set and not to the element one.
  def test_the_window_handlers_are_only_in_the_reflected_set
    %w[onhashchange onpopstate onbeforeunload onstorage onunload onmessage].each do |name|
      assert_includes(reflected_handlers, name)
      refute_includes(element_handlers, name)
    end
  end

  def test_the_boot_wiring_reads_the_sets_rather_than_repeating_them
    assert_includes(BOOT_JS, "__rbHost.elementHandlerAttributes")
    assert_includes(BOOT_JS, "__rbHost.windowReflectedHandlers")
    refute_match(/new Set\(\["on/, BOOT_JS, "the boot wiring must not carry its own copy of the list")
  end

  def test_the_runtime_gates_the_set_attribute_path_on_them
    assert_includes(RUNTIME_JS, "function isHandlerAttribute(el, name)")
    assert_match(/if \(!isHandlerAttribute\(el, name\)\) return;/, RUNTIME_JS)
  end
end
