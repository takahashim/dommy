# frozen_string_literal: true

module Dommy
  # `window.history` polyfill. Stack-based; back/forward move the
  # cursor. pushState appends; replaceState mutates the current entry.
  # Each entry is `{ state:, url: }`. Popstate fires when back /
  # forward triggers a different cursor (not on pushState per spec).
  class History
    def initialize(window, location)
      @window = window
      @location = location
      # Initial entry mirrors the live Location. Bookmark URL is
      # resynthesized lazily from Location each time we read it.
      @stack = [{state: nil, url: nil}]
      @cursor = 0
      @scroll_restoration = "auto"
    end

    def __js_get__(key)
      case key
      when "length"
        @stack.size
      when "state"
        @stack[@cursor][:state]
      when "scrollRestoration"
        @scroll_restoration
      end
    end

    def __js_set__(key, value)
      case key
      when "scrollRestoration"
        # Per spec, only "auto" and "manual" are accepted. Invalid
        # values silently retain the current value.
        v = value.to_s
        @scroll_restoration = v if %w[auto manual].include?(v)
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[pushState replaceState back forward go]
    def __js_call__(method, args)
      case method
      when "pushState"
        push(args[0], args[2])
      when "replaceState"
        replace(args[0], args[2])
      when "back"
        go(-1)
      when "forward"
        go(1)
      when "go"
        go((args[0] || 0).to_i)
      end
    end

    private

    def push(state, url)
      resolved = resolve_url!(url)
      @stack = @stack[0..@cursor]
      @location.__internal_set_url__(resolved) if resolved
      # WHATWG: pushState serializes the state via structured-clone
      # so subsequent caller-side mutation of the original cannot
      # affect history.state.
      @stack << {state: Dommy.structured_clone(state), url: nil}
      @cursor = @stack.size - 1
    end

    def replace(state, url)
      resolved = resolve_url!(url)
      @location.__internal_set_url__(resolved) if resolved
      @stack[@cursor] = {state: Dommy.structured_clone(state), url: nil}
    end

    # WHATWG "URL and history update steps": resolve the given URL against the
    # document URL; a parse failure or a cross-origin result is a SecurityError
    # (same-document history entries must stay same-origin).
    def resolve_url!(url)
      return nil if url.nil? || url.equal?(Bridge::UNDEFINED)

      current = @location.href.to_s
      resolved =
        begin
          current.empty? ? URL.new(url.to_s) : URL.new(url.to_s, current)
        rescue StandardError
          raise DOMException::SecurityError, "A history state object with URL '#{url}' cannot be created in a document with URL '#{current}'."
        end

      unless current.empty?
        if resolved.origin != URL.new(current).origin
          raise DOMException::SecurityError, "A history state object with URL '#{resolved.href}' cannot be created in a document with origin '#{URL.new(current).origin}'."
        end
      end

      resolved.href
    end

    def go(delta)
      target = @cursor + delta
      return if target < 0 || target >= @stack.size

      @cursor = target
      @window.fire_popstate(@stack[@cursor][:state])
    end
  end
end
