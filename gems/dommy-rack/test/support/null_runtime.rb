# frozen_string_literal: true

module DommyRackTestSupport
  # A conforming `Dommy::Js::Runtime` that runs no JavaScript, used to drive the
  # SessionRuntime / Trace stack without a real engine (QuickJS lives in
  # dommy-js-quickjs). Boot calls are recorded; console / rejection channels are
  # exposed so a test can simulate what a real engine surfaces.
  #
  # To exercise the full trace path through real boot, `load_script` /
  # `load_script_cached` recognize sentinels in a script body:
  #   "__log__:<text>"   -> drives the on_log channel (a console.* call)
  #   "__error__:<text>" -> drives on_unhandled_rejection (an uncaught error)
  # so an HTML fixture like `<script>__log__:hi</script>` produces a real
  # `:console` event during boot.
  class NullRuntime
    attr_reader :ready_states, :loaded_scripts, :module_loader

    def initialize
      @ready_states = []
      @loaded_scripts = []
    end

    def on_unhandled_rejection(&block) = @rejection_handler = block
    def on_log(&block) = @log_handler = block

    def install_window(_window) = nil
    def install_browser_globals = nil
    def define_host_object(_name, _object) = nil
    def dispose = nil

    def set_document_ready_state(state) = @ready_states << state

    def module_loader=(loader)
      @module_loader = loader
    end

    def load_script(js)
      @loaded_scripts << js
      drive_sentinels(js)
    end

    def load_script_cached(js, cache_key:)
      @loaded_scripts << js
      drive_sentinels(js)
    end

    def load_module_url(url) = @loaded_scripts << url

    def execute(_js) = nil
    def evaluate(_js) = nil
    def settle = nil
    def drain_microtasks = nil

    private

    def drive_sentinels(js)
      js.to_s.scan(/__log__:(\S+)/) { |(text)| @log_handler&.call(level: "log", text: text) }
      js.to_s.scan(/__error__:(\S+)/) { |(text)| @rejection_handler&.call(RuntimeError.new(text)) }
    end
  end

  module NullRuntimeBackend
    module_function

    # Register :null and point the session's JS factory at a SessionRuntime over
    # it. Returns the previous factory so a test can restore it in teardown.
    def install
      Dommy::Js.register_runtime(:null) { NullRuntime.new } unless Dommy::Js.runtime_registered?(:null)
      previous = Dommy::Rack::Session.javascript_runtime_factory
      Dommy::Rack::Session.javascript_runtime_factory = ->(session) { Dommy::Rack::SessionRuntime.new(session) }
      previous
    end

    def restore(previous)
      Dommy::Rack::Session.javascript_runtime_factory = previous
    end
  end
end
