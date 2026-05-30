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
      @geolocation = Geolocation.new(window)
      @vibration_log = []
      @wake_lock = WakeLock.new(window)
      @locks = LockManager.new(window)
      @storage = StorageManager.new(window)
    end

    attr_reader :clipboard, :permissions, :geolocation, :wake_lock, :locks, :storage

    # Web Share API. Returns a Promise; tests can inspect
    # `__test_last_shared__` to verify what was offered.
    def share(data = nil)
      @last_shared = data
      PromiseValue.resolve(@window, nil)
    end

    def can_share(_data = nil)
      true
    end

    alias canShare can_share

    # Vibration API. No-op in dommy, but the requested pattern is
    # recorded so tests can assert "we asked to vibrate".
    def vibrate(pattern)
      list = pattern.is_a?(Array) ? pattern : [pattern]
      @vibration_log << list.map(&:to_i)
      true
    end

    def __test_vibration_log__
      @vibration_log.dup
    end

    def __test_last_shared__
      @last_shared
    end

    # Battery Status API stub. Returns a Promise resolving to a fixed
    # `BatteryManager` snapshot.
    def get_battery
      PromiseValue.resolve(@window, BatteryManager.new)
    end

    alias getBattery get_battery

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
      when "geolocation"
        @geolocation
      when "wakeLock"
        @wake_lock
      when "locks"
        @locks
      when "storage"
        @storage
      end
    end

    include Bridge::Methods
    js_methods %w[share canShare vibrate getBattery]
    def __js_call__(method, args)
      case method
      when "share"
        share(args[0])
      when "canShare"
        can_share(args[0])
      when "vibrate"
        vibrate(args[0])
      when "getBattery"
        get_battery
      end
    end

    def __js_set__(_key, _value)
      Bridge::UNHANDLED
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
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[readText writeText read write addEventListener removeEventListener dispatchEvent]
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

    def __internal_event_parent__
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
      status&.__internal_set_state__(state.to_s)
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
      Bridge::UNHANDLED
    end

    include Bridge::Methods
    js_methods %w[query]
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

    def __internal_set_state__(new_state)
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
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[addEventListener removeEventListener dispatchEvent]
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

    def __internal_event_parent__
      nil
    end
  end

  # `navigator.geolocation` — stub Geolocation API. Real implementations
  # query the OS; dommy holds a mock position tests configure via
  # `__test_set_position__(coords)` or `__test_set_error__(error_code)`.
  #
  # Spec: https://www.w3.org/TR/geolocation/
  class Geolocation
    DEFAULT_COORDS = {
      "latitude" => 0.0,
      "longitude" => 0.0,
      "accuracy" => 0.0,
      "altitude" => nil,
      "altitudeAccuracy" => nil,
      "heading" => nil,
      "speed" => nil
    }.freeze

    def initialize(window)
      @window = window
      @position = nil
      @error = nil
      @watches = {}
      @next_watch_id = 0
    end

    # Test seam: install a mock position.
    def __test_set_position__(coords = {})
      merged = DEFAULT_COORDS.merge(coords.transform_keys(&:to_s))
      @position = {"coords" => merged, "timestamp" => @window.scheduler.now_ms}
      @error = nil
    end

    # Test seam: install a permission/positioning error (code 1=PERMISSION_DENIED,
    # 2=POSITION_UNAVAILABLE, 3=TIMEOUT).
    def __test_set_error__(code, message = "")
      @position = nil
      @error = {"code" => code.to_i, "message" => message.to_s}
    end

    def get_current_position(success, failure = nil, _options = nil)
      @window.scheduler.queue_microtask(proc { deliver(success, failure) })
      nil
    end

    alias getCurrentPosition get_current_position

    def watch_position(success, failure = nil, _options = nil)
      id = (@next_watch_id += 1)
      @watches[id] = [success, failure]
      @window.scheduler.queue_microtask(proc { deliver(success, failure) })
      id
    end

    alias watchPosition watch_position

    def clear_watch(id)
      @watches.delete(id)
      nil
    end

    alias clearWatch clear_watch

    include Bridge::Methods
    js_methods %w[getCurrentPosition watchPosition clearWatch]
    def __js_call__(method, args)
      case method
      when "getCurrentPosition"
        get_current_position(args[0], args[1], args[2])
      when "watchPosition"
        watch_position(args[0], args[1], args[2])
      when "clearWatch"
        clear_watch(args[0])
      end
    end

    private

    def deliver(success, failure)
      if @position
        invoke(success, @position)
      else
        invoke(failure, @error || {"code" => 2, "message" => "POSITION_UNAVAILABLE"})
      end
    end

    def invoke(callback, payload)
      return if callback.nil?

      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", [payload])
      elsif callback.respond_to?(:call)
        callback.call(payload)
      end
    end
  end

  # `navigator.wakeLock` — Screen Wake Lock API stub. `request(type)`
  # returns a Promise of a `WakeLockSentinel` whose `release()` flips
  # `released` and dispatches a `release` event.
  #
  # Spec: https://www.w3.org/TR/screen-wake-lock/
  class WakeLock
    def initialize(window)
      @window = window
    end

    def request(type = "screen")
      PromiseValue.resolve(@window, WakeLockSentinel.new(@window, type.to_s))
    end

    include Bridge::Methods
    js_methods %w[request]
    def __js_call__(method, args)
      case method
      when "request"
        request(args[0] || "screen")
      end
    end
  end

  class WakeLockSentinel
    include EventTarget

    attr_reader :type

    def initialize(window, type)
      @window = window
      @type = type
      @released = false
    end

    def released
      @released
    end

    def release
      return PromiseValue.resolve(@window, nil) if @released

      @released = true
      dispatch_event(Event.new("release"))
      PromiseValue.resolve(@window, nil)
    end

    def __js_get__(key)
      case key
      when "type"
        @type
      when "released"
        @released
      end
    end

    include Bridge::Methods
    js_methods %w[release]
    def __js_call__(method, _args)
      case method
      when "release"
        release
      end
    end

    def __internal_event_parent__
      nil
    end
  end

  # `navigator.getBattery()` returns one of these. Fixed snapshot —
  # tests that need different values can stub.
  class BatteryManager
    include EventTarget

    attr_reader :charging, :charging_time, :discharging_time, :level

    def initialize(charging: true, level: 1.0, charging_time: 0, discharging_time: Float::INFINITY)
      @charging = charging
      @level = level
      @charging_time = charging_time
      @discharging_time = discharging_time
    end

    def __js_get__(key)
      case key
      when "charging"
        @charging
      when "chargingTime"
        @charging_time
      when "dischargingTime"
        @discharging_time
      when "level"
        @level
      end
    end

    def __internal_event_parent__
      nil
    end
  end

  # `navigator.locks` — Web Locks API. Locks are scoped to the
  # Navigator instance; serial execution per name. Real browsers
  # coordinate across tabs; dommy is single-process so it just
  # serializes calls within the same Window.
  #
  # Spec: https://w3c.github.io/web-locks/
  class LockManager
    def initialize(window)
      @window = window
      @held = {}
    end

    def request(name, options_or_callback, callback = nil)
      if options_or_callback.is_a?(Hash) || options_or_callback.nil?
        options = options_or_callback || {}
        cb = callback
      else
        options = {}
        cb = options_or_callback
      end

      key = name.to_s
      if @held[key] && options["ifAvailable"]
        return invoke_with_lock(cb, nil)
      end

      lock = Lock.new(key, options["mode"] || "exclusive")
      @held[key] = lock
      result = invoke_with_lock(cb, lock)
      @held.delete(key)
      result
    end

    def query
      held = @held.map { |name, lock| {"name" => name, "mode" => lock.mode, "clientId" => "dommy"} }
      PromiseValue.resolve(@window, {"held" => held, "pending" => []})
    end

    include Bridge::Methods
    js_methods %w[request query]
    def __js_call__(method, args)
      case method
      when "request"
        request(args[0], args[1], args[2])
      when "query"
        query
      end
    end

    private

    def invoke_with_lock(callback, lock)
      value = if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", [lock])
      elsif callback.respond_to?(:call)
        callback.call(lock)
      end

      PromiseValue.resolve(@window, value)
    end
  end

  Lock = Struct.new(:name, :mode) do
    def __js_get__(key)
      case key
      when "name"
        name
      when "mode"
        mode
      end
    end
  end

  # `navigator.storage` — StorageManager API. Returns fixed-value
  # estimates; `persist`/`persisted` always resolve `true`.
  #
  # Spec: https://storage.spec.whatwg.org/
  class StorageManager
    def initialize(window)
      @window = window
      @persisted = false
    end

    def estimate
      PromiseValue.resolve(@window, {"quota" => 1_073_741_824, "usage" => 0, "usageDetails" => {}})
    end

    def persist
      @persisted = true
      PromiseValue.resolve(@window, true)
    end

    def persisted
      PromiseValue.resolve(@window, @persisted)
    end

    include Bridge::Methods
    js_methods %w[estimate persist persisted]
    def __js_call__(method, _args)
      case method
      when "estimate"
        estimate
      when "persist"
        persist
      when "persisted"
        persisted
      end
    end
  end
end
