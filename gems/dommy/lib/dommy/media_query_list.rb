# frozen_string_literal: true

require_relative "internal/css/media_query"

module Dommy
  # `MediaQueryList` — what `window.matchMedia(query)` returns.
  #
  # `matches` evaluates the query against the window's media environment
  # (viewport 1280x720 by default; see Window#resize_to). When the
  # environment changes, the window notifies every list it handed out and a
  # `change` event fires for those whose result flipped.
  #
  # `__test_set_matches__(bool)` remains as a test seam: it forces the
  # match state (overriding evaluation) and fires `change` — the surface
  # libraries like Material-UI / Bootstrap / @testing-library consult.
  #
  # Spec: https://drafts.csswg.org/cssom-view/#mediaquerylist
  class MediaQueryList
    include EventTarget

    attr_reader :media

    def initialize(window, query)
      @window = window
      @media = query.to_s
      @forced = nil
      @onchange = nil
      @last_matches = evaluate
      window.__register_media_query_list__(self) if window.respond_to?(:__register_media_query_list__)
    end

    def matches
      return @forced unless @forced.nil?

      @last_matches = evaluate
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

    # Test seam: force the match state (evaluation is bypassed from then
    # on) and dispatch a `change` event so subscribers re-render.
    def __test_set_matches__(value)
      return if matches == !!value

      @forced = !!value
      dispatch_change(@forced)
      nil
    end

    # Called by the window when the media environment changed (resize etc.).
    # Fires `change` when the evaluated result flipped; a forced value wins.
    def __environment_changed__
      return unless @forced.nil?

      current = evaluate
      return if current == @last_matches

      @last_matches = current
      dispatch_change(current)
      nil
    end

    def __js_get__(key)
      case key
      when "media"
        @media
      when "matches"
        matches
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
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    # `matches` is a read-only attribute (boolean), exposed through __js_get__ —
    # not a method. Listing it here would shadow the getter with a callable, so
    # `mql.matches` would evaluate to a function instead of the boolean.
    js_methods %w[
      addListener removeListener addEventListener removeEventListener dispatchEvent
    ]
    def __js_call__(method, args)
      case method
      when "addListener"
        add_listener(args[0])
      when "removeListener"
        remove_listener(args[0])
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

    private

    def evaluate
      Internal::CSS::MediaQuery.match?(@media, @window.media_environment)
    end

    def dispatch_change(matches)
      dispatch_event(MediaQueryListEvent.new("change", "matches" => matches, "media" => @media))
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
