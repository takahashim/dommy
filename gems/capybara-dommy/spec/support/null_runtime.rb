# frozen_string_literal: true

module CapybaraDommyJsSupport
  # A conforming `Dommy::Js::Runtime` that runs no JavaScript, so the
  # `javascript: true` driver path (event dispatch, default actions, script
  # delegation, disposal) can be exercised without dommy-js-quickjs. The DOM
  # event synthesis under test is Ruby-side; Ruby listeners observe it.
  # `execute` / `evaluate` record their scripts so a spec can assert the
  # driver delegated to the runtime.
  class NullRuntime
    attr_reader :executed, :evaluated, :disposed

    def initialize
      @executed = []
      @evaluated = []
      @disposed = false
    end

    def on_unhandled_rejection(&block) = @rejection_handler = block
    def on_log(&block) = @log_handler = block

    def install_window(_window) = nil
    def install_browser_globals = nil
    def define_host_object(_name, _object) = nil
    def dispose = @disposed = true

    def set_document_ready_state(_state) = nil
    attr_writer :module_loader

    def load_script(_js) = nil
    def load_script_cached(_js, cache_key:) = nil
    def load_module_url(_url) = nil

    def execute(js) = @executed << js
    def evaluate(js)
      @evaluated << js
      "evaluated:#{js}"
    end

    def settle = nil
    def drain_microtasks = nil
  end

  module_function

  # Point the session's JS factory at a SessionRuntime over NullRuntime,
  # collecting each built runtime into `runtimes`. Returns the previous
  # factory for #restore.
  def install(runtimes)
    Dommy::Js.register_runtime(:null) { NullRuntime.new.tap { |r| runtimes << r } }
    previous = Dommy::Rack::Session.javascript_runtime_factory
    Dommy::Rack::Session.javascript_runtime_factory =
      ->(session) { Dommy::Rack::SessionRuntime.new(session) }
    previous
  end

  def restore(previous)
    Dommy::Rack::Session.javascript_runtime_factory = previous
  end
end
