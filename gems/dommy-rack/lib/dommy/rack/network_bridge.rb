# frozen_string_literal: true

require_relative "resources"

module Dommy
  module Rack
    # Routes the document's fetch / XMLHttpRequest polyfills to the session's
    # Rack application. Installed as the window's `__fetch_handler__` — the
    # resolver Dommy's network polyfills consult before their stub maps — so
    # same-origin requests hit the real app (sharing the session's cookie jar),
    # while cross-origin URLs fall through to whatever stubs the test installed.
    #
    # A thin installer over the unified resources interface: it wires a
    # `Dommy::Resources::FetchHandler` backed by `Dommy::Rack::Resources`, so
    # `fetch` / XHR and `<script src>` loads resolve through the same adapter.
    module NetworkBridge
      # Wire a bridge for `session` into `window`. Returns the fetch handler.
      def self.install(session, window)
        handler = Dommy::Resources::FetchHandler.new(Resources.new(session))
        window.globals["__fetch_handler__"] = handler
        handler
      end
    end
  end
end
