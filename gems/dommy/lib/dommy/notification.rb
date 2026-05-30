# frozen_string_literal: true

module Dommy
  # `Notification` polyfill. Real browsers prompt the user; dommy
  # exposes the permission state as a class-level slot tests can
  # toggle via `Notification.__test_set_permission__("granted")`.
  #
  # Spec: https://notifications.spec.whatwg.org/
  class Notification
    include EventTarget

    @permission = "default"

    class << self
      attr_reader :permission

      def __test_set_permission__(value)
        @permission = value.to_s
      end

      # Asynchronous spec API: returns a Promise (here a value that
      # `.await`-able). Callbacks receive the current permission
      # value.
      def request_permission(window, callback = nil)
        promise = PromiseValue.resolve(window, @permission)
        if callback.respond_to?(:__js_call__)
          callback.__js_call__("call", [@permission])
        elsif callback.respond_to?(:call)
          callback.call(@permission)
        end

        promise
      end
    end

    attr_reader :title, :body, :icon, :tag, :data

    def initialize(window, title, options = nil)
      @window = window
      @title = title.to_s
      opts = options.is_a?(Hash) ? options : {}
      @body = (opts["body"] || opts[:body] || "").to_s
      @icon = (opts["icon"] || opts[:icon] || "").to_s
      @tag = (opts["tag"] || opts[:tag] || "").to_s
      @data = opts["data"] || opts[:data]
      @closed = false
    end

    def close
      return if @closed

      @closed = true
      dispatch_event(Event.new("close"))
      nil
    end

    def __js_get__(key)
      case key
      when "title"
        @title
      when "body"
        @body
      when "icon"
        @icon
      when "tag"
        @tag
      when "data"
        @data
      end
    end

    include Bridge::Methods
    js_methods %w[close addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, args)
      case method
      when "close"
        close
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end
  end
end
