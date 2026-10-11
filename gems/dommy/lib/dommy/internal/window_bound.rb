# frozen_string_literal: true

module Dommy
  module Internal
    # An event target that is not a node and is made for one window (an
    # XMLHttpRequest, a WebSocket, a MessagePort, …): that window is its
    # relevant global, whose `event` its listeners see set while they run and
    # where what they throw is reported. The including class keeps the window
    # it was made for in @window.
    module WindowBound
      def __internal_relevant_window__ = @window
    end
  end
end
