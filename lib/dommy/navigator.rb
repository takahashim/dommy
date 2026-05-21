# frozen_string_literal: true

module Dommy
  # `window.navigator` — exposes browser-agent metadata plus
  # `clipboard` / `permissions` sub-objects. Dommy returns sensible
  # defaults (Dommy as user agent, "en" language, online=true) that
  # tests can override.
  class Navigator
    DEFAULT_USER_AGENT = "Mozilla/5.0 (Dommy) Ruby"

    attr_accessor :user_agent, :language, :languages, :platform, :vendor, :on_line, :cookie_enabled

    def initialize(window)
      @window = window
      @user_agent = DEFAULT_USER_AGENT
      @language = "en"
      @languages = ["en"].freeze
      @platform = "Dommy"
      @vendor = "Dommy"
      @on_line = true
      @cookie_enabled = true
      @clipboard = Clipboard.new(window)
      @permissions = Permissions.new(window)
    end

    attr_reader :clipboard, :permissions

    def [](key)
      __js_get__(key.to_s)
    end

    def []=(k, v)
      __js_set__(k.to_s, v)
    end

    def __js_get__(key)
      case key
      when "userAgent"
        @user_agent
      when "language"
        @language
      when "languages"
        @languages
      when "platform"
        @platform
      when "vendor"
        @vendor
      when "onLine"
        @on_line
      when "cookieEnabled"
        @cookie_enabled
      when "clipboard"
        @clipboard
      when "permissions"
        @permissions
      end
    end

    def __js_set__(_key, _value)
      nil
    end
  end

  # `navigator.clipboard` — an in-memory clipboard for tests. Real
  # OS clipboard access is intentionally not implemented; reads and
  # writes round-trip through Ruby memory only.
  #
  # Async APIs (`readText`/`writeText`/`read`/`write`) return
  # PromiseValue so callers' `.await` chains keep working.
  class Clipboard
    include EventTarget

    def initialize(window)
      @window = window
      @text = ""
      @items = []
    end

    # Sync read for tests that don't want to await.
    def text
      @text
    end

    def text=(value)
      @text = value.to_s
    end

    def read_text
      PromiseValue.resolve(@window, @text)
    end

    def write_text(text)
      @text = text.to_s
      PromiseValue.resolve(@window, nil)
    end

    def read
      PromiseValue.resolve(@window, @items.dup)
    end

    def write(items)
      @items = items.is_a?(Array) ? items : [items]
      PromiseValue.resolve(@window, nil)
    end

    def __js_get__(_key)
      nil
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "readText"
        read_text
      when "writeText"
        write_text(args[0])
      when "read"
        read
      when "write"
        write(args[0])
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __event_parent__
      nil
    end
  end

  # `navigator.permissions` — query returns a PermissionStatus whose
  # `state` defaults to "granted" for every recognized name. Tests
  # can override via `permissions.set("name", "denied")` before
  # exercising user code.
  class Permissions
    KNOWN_NAMES = %w[
      geolocation
      notifications
      push
      midi
      camera
      microphone
      clipboard-read
      clipboard-write
      background-fetch
      background-sync
      persistent-storage
      accelerometer
      gyroscope
      magnetometer
      screen-wake-lock
      storage-access
      window-management
    ]
      .freeze

    def initialize(window)
      @window = window
      @overrides = {}
    end

    # Test helper: override the resolved state for a permission name.
    # Subsequent `query()` calls will see the new value, and existing
    # PermissionStatus objects fire `change` events.
    def set(name, state)
      key = name.to_s
      @overrides[key] = state.to_s
      @statuses ||= {}
      status = @statuses[key]
      status&.__set_state__(state.to_s)
      nil
    end

    def query(descriptor)
      name = if descriptor.is_a?(Hash)
        (descriptor["name"] || descriptor[:name]).to_s
      else
        descriptor.to_s
      end

      state = @overrides[name] || "granted"
      @statuses ||= {}
      status = @statuses[name] ||= PermissionStatus.new(@window, name, state)
      PromiseValue.resolve(@window, status)
    end

    def __js_get__(_key)
      nil
    end

    def __js_set__(_key, _value)
      nil
    end

    def __js_call__(method, args)
      case method
      when "query"
        query(args[0])
      end
    end
  end

  # `PermissionStatus` — `state` + `onchange` event handler. Fires a
  # `change` event when `Permissions#set` mutates the underlying
  # value (mirrors browser behavior where the user toggles a
  # permission).
  class PermissionStatus
    include EventTarget

    attr_reader :name, :state

    def initialize(window, name, state)
      @window = window
      @name = name
      @state = state
      @onchange = nil
    end

    def __set_state__(new_state)
      return if @state == new_state

      @state = new_state
      dispatch_event(Event.new("change"))
    end

    def __js_get__(key)
      case key
      when "name"
        @name
      when "state"
        @state
      when "onchange"
        @onchange
      end
    end

    def __js_set__(key, value)
      case key
      when "onchange"
        # Assigning to onchange overwrites the previous handler.
        remove_event_listener("change", @onchange) if @onchange
        @onchange = value
        add_event_listener("change", value) if value
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __event_parent__
      nil
    end
  end
end
