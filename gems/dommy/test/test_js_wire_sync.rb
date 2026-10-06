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
    Dommy::Bridge::WireTags.constants.each do |const|
      tag = Dommy::Bridge::WireTags.const_get(const)
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
    tags = Dommy::Bridge::WireTags.constants.map { |c| Dommy::Bridge::WireTags.const_get(c) }.grep(String)
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

# Which `on*` names are event handlers is generated from the specs' IDL
# (script/build_event_handlers.rb) into one JS and one Ruby table: the bridge's
# chain lookup and the host's attribute change steps read the same data.
# An `on*` attribute outside them names no event handler and must stay inert.
# WPT: html/webappapis/scripting/events/event-handler-non-content-document-idl-attributes.html
class TestEventHandlerContentAttributes < Minitest::Test
  RUNTIME_JS = Dommy::Js::HostBridge::HOST_RUNTIME_JS
  HANDLERS_JS = Dommy::Js::HostBridge::WEBIDL_EVENT_HANDLERS_JS
  Tables = Dommy::Internal::EventHandlerTables

  def element_handlers = Dommy::Internal::EventHandlers::GLOBAL
  def reflected_handlers = Dommy::Internal::EventHandlers::WINDOW

  # IDL attributes of Document (and Element for the fullscreen pair); none of
  # them is a content attribute on any element.
  DOCUMENT_ONLY = %w[onreadystatechange onvisibilitychange onfullscreenchange onfullscreenerror].freeze

  def test_the_document_only_handlers_are_in_neither_set
    DOCUMENT_ONLY.each do |name|
      refute_includes(element_handlers, name)
      refute_includes(reflected_handlers, name)
      assert_includes(Tables::BY_INTERFACE["Document"], name)
    end
  end

  def test_the_element_set_covers_the_handlers_elements_actually_have
    %w[
      onclick oninput onsubmit ontoggle onwheel onscrollend onslotchange onsecuritypolicyviolation
      onpointerdown onpointerrawupdate ongotpointercapture ontouchstart onanimationstart
      ontransitionend onselectstart onselectionchange oncommand oncontextlost onbeforematch
    ].each { |name| assert_includes(element_handlers, name) }
    # Not in any spec's GlobalEventHandlers.
    %w[onfocusin onfocusout onpointerlockchange].each { |name| refute_includes(element_handlers, name) }
  end

  # The Window handlers are content attributes on body and frameset only, so
  # they belong to the reflected set and not to the element one.
  def test_the_window_handlers_are_only_in_the_reflected_set
    %w[onhashchange onpopstate onbeforeunload onstorage onunload onmessage].each do |name|
      assert_includes(reflected_handlers, name)
      refute_includes(element_handlers, name)
    end
    assert_equal(reflected_handlers | %w[onblur onerror onfocus onload onresize onscroll],
                 Dommy::Internal::EventHandlers::BODY_REFLECTED)
  end

  # The JS table is the Ruby one, interface for interface.
  def test_the_bridge_reads_the_same_table_as_the_host
    js = HANDLERS_JS.scan(/^  "(\w+)": \[(.*)\]/).to_h { |name, list| [name, list.scan(/"([^"]+)"/).flatten] }
    assert_equal(Tables::BY_INTERFACE.transform_values(&:to_a), js)
    refute_match(%r{/\^on\[a-z\]/\.test\(prop\)\) return true}, RUNTIME_JS, "the has trap must look names up, not match them")
  end

  # Compilation is the engine's: host_runtime builds the function, Ruby only
  # stores the body until then.
  def test_the_runtime_compiles_handlers
    assert_includes(RUNTIME_JS, "function compileEventHandler(wireEl, name, code, windowHandler)")
    boot = Dommy::Js::ScriptBoot.method(:wire_inline_handlers).source_location
    refute_match(/new Function\(/, ::File.read(boot.first), "the boot wiring must not compile handlers of its own")
  end
end

# A stub reached through the prototype (`Element.prototype.remove.call(el)`, or
# a `super.method()` in a custom element) must invalidate the DOM-epoch caches
# around a mutating call exactly as the proxy's own get trap does — otherwise
# the DOM changes underneath a cached parentNode and the next read hands back
# the state from before the call.
# WPT: html/semantics/forms/the-select-element/select-remove.html
class TestProtoMethodStubsInvalidateCaches < Minitest::Test
  RUNTIME_JS = Dommy::Js::HostBridge::HOST_RUNTIME_JS

  def test_the_stub_routes_a_mutating_call_through_the_epoch_bump
    assert_includes(RUNTIME_JS, "function callMutating(handle, name, wire, iface)")
    assert_match(/readOnly\n\s+\? hostCallResult\(name, __rb_host_call\(this\[HKEY\], name, wire\), iface\)\n\s+: callMutating\(/, RUNTIME_JS)
  end

  def test_the_read_only_set_is_what_decides
    assert_match(/const readOnly = NON_MUTATING_METHODS\.has\(name\);/, RUNTIME_JS)
  end

  def test_callMutating_bumps_on_both_sides_of_the_call
    body = RUNTIME_JS[/function callMutating\(handle, name, wire, iface\) \{(.*?)\n  \}/m, 1]
    refute_nil(body)
    assert_equal(2, body.scan("bumpDomEpoch()").size, "the epoch is bumped before and after the host call")
    assert_includes(body, "finally", "the trailing bump has to survive a throwing call")
  end
end
