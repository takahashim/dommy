# frozen_string_literal: true

module Dommy
  # `window.screen` — the Screen interface. A headless browser has no physical
  # display, so the screen reports the (approximate) viewport size, with standard
  # desktop colour depth and an orientation derived from the aspect ratio.
  #
  # `window.screen` is always present in a real browser, and `screen.width` /
  # `screen.height` are routinely read *unguarded* (analytics, responsive logic),
  # so a missing `screen` makes them throw "cannot read property 'width' of
  # undefined" — which is exactly what real sites hit when Dommy lacked it.
  class Screen
    def initialize(window)
      @window = window
    end

    def __js_get__(key)
      case key
      when "width", "availWidth"
        @window.inner_width
      when "height", "availHeight"
        @window.inner_height
      when "availLeft", "availTop"
        0
      when "colorDepth", "pixelDepth"
        24
      when "isExtended"
        false
      when "orientation"
        @orientation ||= ScreenOrientation.new(@window)
      else
        # Anything else is genuinely absent (JS `undefined`, `"x" in screen`
        # false) so feature detection takes the not-supported path.
        Bridge::ABSENT
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    # Screen is an EventTarget; Dommy never fires screen events, so a listener is
    # accepted and simply never invoked.
    js_methods %w[addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, _args)
      case method
      when "addEventListener", "removeEventListener" then nil
      when "dispatchEvent" then true
      end
    end
  end

  # `screen.orientation` — the ScreenOrientation interface. Reports a fixed
  # orientation from the viewport aspect ratio; `lock`/`unlock` are no-ops (a
  # headless browser cannot rotate), `lock` still returning a resolved Promise so
  # callers that `await screen.orientation.lock(...)` proceed.
  class ScreenOrientation
    def initialize(window)
      @window = window
    end

    def __js_get__(key)
      case key
      when "type"
        @window.inner_width >= @window.inner_height ? "landscape-primary" : "portrait-primary"
      when "angle"
        0
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[lock unlock addEventListener removeEventListener dispatchEvent]
    def __js_call__(method, _args)
      case method
      when "lock"
        PromiseValue.resolve(@window, nil)
      when "unlock", "addEventListener", "removeEventListener"
        nil
      when "dispatchEvent"
        true
      end
    end
  end
end
