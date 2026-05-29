# frozen_string_literal: true

module Dommy
  # `MediaQueryList` — what `window.matchMedia(query)` returns.
  #
  # Dommy has no layout / viewport, so `matches` is `false` by default.
  # Tests drive media query changes via `__test_set_matches__(bool)`, which
  # flips the boolean and fires a `change` event — exactly the surface
  # libraries like Material-UI / Bootstrap / @testing-library consult.
  #
  # Spec: https://drafts.csswg.org/cssom-view/#mediaquerylist
  class MediaQueryList
    include EventTarget

    attr_reader :media

    def initialize(window, query)
      @window = window
      @media = query.to_s
      @matches = false
      @onchange = nil
    end

    def matches
      @matches
    end

    alias matches? matches

    # Spec aliases for legacy support.
    def add_listener(callback)
      add_event_listener("change", callback)
    end

    alias addListener add_listener

    def remove_listener(callback)
      remove_event_listener("change", callback)
    end

    alias removeListener remove_listener

    # Test seam: flip the match state and dispatch a `change` event so
    # subscribers re-render.
    def __test_set_matches__(value)
      return if @matches == !!value

      @matches = !!value
      dispatch_event(MediaQueryListEvent.new("change", "matches" => @matches, "media" => @media))
      nil
    end

    def __js_get__(key)
      case key
      when "media"
        @media
      when "matches"
        @matches
      when "onchange"
        @onchange
      end
    end

    def __js_set__(key, value)
      case key
      when "onchange"
        remove_event_listener("change", @onchange) if @onchange
        @onchange = value
        add_event_listener("change", value) if value
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "matches"
        @matches
      when "addListener"
        add_listener(args[0])
      when "removeListener"
        remove_listener(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end
  end

  # `MediaQueryListEvent` — the `change` event payload.
  class MediaQueryListEvent < Event
    def initialize(type, init = nil)
      super
      @matches = !!read_init(init, "matches")
      @media = (read_init(init, "media") || "").to_s
    end

    attr_reader :matches, :media

    def __js_get__(key)
      case key
      when "matches"
        @matches
      when "media"
        @media
      else
        super
      end
    end
  end
end
