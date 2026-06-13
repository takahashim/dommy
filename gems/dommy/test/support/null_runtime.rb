# frozen_string_literal: true

module DommyTestSupport
  # A conforming `Dommy::Js::Runtime` that runs no JavaScript. It lets
  # `Dommy::Browser` boot and exercise its pure-DOM surface — parsing, finding,
  # interaction events, matchers, and strict-mode error accounting — without a
  # real JS engine (the concrete QuickJS backend lives in dommy-js-quickjs).
  #
  # Lifecycle / boot calls are recorded (`ready_states`, `loaded_scripts`) so a
  # test can assert what boot did; the error and console channels are exposed
  # via `emit_unhandled_rejection` / `emit_log` so a test can simulate what a
  # real engine would surface and verify the Browser's strict-mode handling.
  class NullRuntime
    attr_reader :ready_states, :loaded_scripts, :module_loader

    def initialize
      @ready_states = []
      @loaded_scripts = []
    end

    # --- error / console channels (Browser registers these on boot) ---
    def on_unhandled_rejection(&block) = @rejection_handler = block
    def on_log(&block) = @log_handler = block

    # Drive the channels a real engine would feed, for strict-mode tests.
    def emit_unhandled_rejection(error) = @rejection_handler&.call(error)
    def emit_log(entry) = @log_handler&.call(entry)

    # --- lifecycle / wiring (no-ops) ---
    def install_window(_window) = nil
    def install_browser_globals = nil
    def define_host_object(_name, _object) = nil
    def dispose = nil

    # --- script boot (record, don't run) ---
    def set_document_ready_state(state) = @ready_states << state
    def module_loader=(loader)
      @module_loader = loader
    end

    def load_script(js) = @loaded_scripts << js
    def load_script_cached(js, cache_key:) = @loaded_scripts << js
    def load_module_url(url) = @loaded_scripts << url

    # --- driving / settling (no-ops; nothing to run) ---
    def execute(_js) = nil
    def evaluate(_js) = nil
    def settle = nil
    def drain_microtasks = nil
  end
end

# Register once as a backend so `Dommy::Browser.new(backend: :null)` (and the
# default, since this is the only backend registered in this gem's suite) builds
# a fresh NullRuntime.
Dommy::Js.register_runtime(:null) { DommyTestSupport::NullRuntime.new } unless Dommy::Js.runtime_registered?(:null)
