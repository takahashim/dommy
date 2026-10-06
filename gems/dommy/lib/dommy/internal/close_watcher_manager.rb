# frozen_string_literal: true

module Dommy
  module Internal
    # HTML §6.9 "Close requests and close watchers": a window's close watcher
    # manager — its groups of close watchers, the allowed number of groups,
    # and the next-user-interaction-allows-a-new-group flag — with the
    # algorithms that establish, request to close, close, destroy and
    # process close watchers.
    #
    # Modal and closedby dialogs, auto and hint popovers, and CloseWatcher
    # objects all establish their close watchers here, so one close request
    # (Esc, from the driver) closes the topmost of them, and watchers created
    # without an intervening user activation are grouped and close together.
    class CloseWatcherManager
      # A close watcher: its window, its cancel action (given canPreventClose,
      # answering whether to proceed), its close action, its get enabled
      # state, and the is-running-cancel-action flag.
      class Watcher
        attr_reader :window, :manager
        attr_accessor :running_cancel_action

        def initialize(manager, window, cancel_action, close_action, enabled_state)
          @manager = manager
          @window = window
          @cancel_action = cancel_action
          @close_action = close_action
          @enabled_state = enabled_state
          @running_cancel_action = false
        end

        def cancel(can_prevent_close) = @cancel_action.call(can_prevent_close)
        def run_close_action = @close_action.call
        def enabled? = @enabled_state.call ? true : false

        # HTML "active": some group of its window's manager contains it.
        def active? = @manager.contains?(self)

        # HTML "request to close" a close watcher. Answers whether the caller
        # should go on (true) or the cancel action stopped it (false).
        def request_close(require_history_action_activation)
          return true unless active?
          return true unless enabled?
          return true if @running_cancel_action
          return true unless @window.__internal_fully_active__?

          can_prevent_close = !require_history_action_activation ||
            (@manager.groups.size < @manager.allowed_number_of_groups &&
              @window.__internal_history_action_activation__?)
          @running_cancel_action = true
          should_continue =
            begin
              cancel(can_prevent_close)
            ensure
              @running_cancel_action = false
            end
          unless should_continue
            @window.__internal_consume_history_action_user_activation__
            return false
          end

          close
          true
        end

        # HTML "close" a close watcher: destroy it, then run its close action.
        def close
          return unless active?
          return unless enabled?
          return unless @window.__internal_fully_active__?

          destroy
          run_close_action
          nil
        end

        # HTML "destroy" a close watcher.
        def destroy
          @manager.remove(self)
          nil
        end
      end

      attr_reader :groups, :allowed_number_of_groups

      def initialize(window)
        @window = window
        @groups = []
        @allowed_number_of_groups = 1
        @next_user_interaction_allows_a_new_group = true
      end

      def contains?(watcher) = @groups.any? { |group| group.any? { |w| w.equal?(watcher) } }

      # HTML "notify the close watcher manager about user activation".
      def notify_user_activation
        @allowed_number_of_groups += 1 if @next_user_interaction_allows_a_new_group
        @next_user_interaction_allows_a_new_group = false
        nil
      end

      # HTML "establish a close watcher" in this manager's window. The three
      # actions are callables: cancel(canPreventClose) -> Boolean,
      # close() and enabled() -> Boolean.
      def establish(cancel_action:, close_action:, enabled_state: -> { true })
        watcher = Watcher.new(self, @window, cancel_action, close_action, enabled_state)
        if @groups.size < @allowed_number_of_groups
          @groups << [watcher]
        else
          @groups.last << watcher
        end
        @next_user_interaction_allows_a_new_group = true
        watcher
      end

      def remove(watcher)
        @groups.each { |group| group.reject! { |w| w.equal?(watcher) } }
        @groups.reject!(&:empty?)
        nil
      end

      # HTML "process close watchers": request to close each watcher of the
      # last group, newest first, until one's cancel action stops the walk.
      # Answers whether a close watcher was processed.
      def process
        processed = false
        unless @groups.empty?
          @groups.last.dup.reverse_each do |watcher|
            processed = true if watcher.enabled?
            break unless watcher.request_close(true)
          end
        end
        @allowed_number_of_groups -= 1 if @allowed_number_of_groups > 1
        processed
      end
    end

    # The window-side half: each Window has one manager, and the "close
    # request steps" a user's close request (Esc) runs against a document.
    module CloseWatcherHost
      def __internal_close_watcher_manager__ = (@close_watcher_manager ||= CloseWatcherManager.new(self))

      # HTML's close request steps for this window's document, after the
      # relevant event (the Esc keydown) was fired and not canceled: a
      # fullscreen document exits fullscreen; otherwise the close watchers
      # are processed. Answers whether something was closed.
      def __internal_close_request__
        document = self.document
        if document.respond_to?(:fullscreen_element) && document.fullscreen_element
          document.__js_call__("exitFullscreen", []) if document.respond_to?(:__js_call__)
          return true
        end
        return false unless __internal_fully_active__?

        __internal_close_watcher_manager__.process
      end
    end
  end

  # HTML's CloseWatcher interface: a script-created close watcher that fires
  # `cancel` (cancelable only while the page may prevent a close) and
  # `close` at itself.
  class CloseWatcher
    include EventTarget

    def initialize(window, options = nil)
      @window = window
      unless window.__internal_fully_active__?
        raise DOMException::InvalidStateError, "the document is not fully active"
      end

      target = self
      @watcher = window.__internal_close_watcher_manager__.establish(
        cancel_action: lambda do |can_prevent_close|
          event = Event.new("cancel", "bubbles" => false, "cancelable" => can_prevent_close)
          target.dispatch_event(event.__internal_mark_trusted__)
        end,
        close_action: lambda do
          target.dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
        end
      )
      signal = options.is_a?(Hash) ? (options.key?("signal") ? options["signal"] : options[:signal]) : nil
      return unless signal.is_a?(AbortSignal)

      if signal.aborted?
        @watcher.destroy
      else
        watcher = @watcher
        signal.__internal_add_abort_algorithm__(proc { watcher.destroy })
      end
    end

    def request_close
      @watcher.request_close(false)
      nil
    end

    def close
      @watcher.close
      nil
    end

    def destroy
      @watcher.destroy
      nil
    end

    def __internal_event_parent__ = nil

    def __js_get__(key)
      case key
      when "oncancel", "onclose" then on_handler(event_name_from_on(key))
      else Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless %w[oncancel onclose].include?(key)

      set_on_handler(event_name_from_on(key), value)
      nil
    end

    include Bridge::Methods
    js_methods %w[addEventListener removeEventListener dispatchEvent requestClose close destroy]
    def __js_call__(method, args)
      case method
      when "addEventListener" then add_event_listener(args[0], args[1], args[2])
      when "removeEventListener" then remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent" then dispatch_event(args[0])
      when "requestClose", "close", "destroy"
        # The three operations return undefined.
        __send__({ "requestClose" => :request_close, "close" => :close, "destroy" => :destroy }[method])
        Bridge::UNDEFINED
      end
    end
  end
end
