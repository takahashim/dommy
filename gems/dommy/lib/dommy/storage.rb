# frozen_string_literal: true

module Dommy
  # The storage areas a browsing session's windows share (HTML "storage
  # bottle"s). localStorage has one area per origin; sessionStorage one per
  # top-level browsing session and origin — a provider stands for one session,
  # so it keeps one of each per origin. An embedder hands the same provider to
  # every window of the session (Window#storage_provider=), which is what makes
  # a value one page stored visible to the next page of the same origin, and a
  # change made in one window fire `storage` at the others.
  class StorageProvider
    def initialize
      @local = {}
      @session = {}
      @windows = ObjectSpace::WeakMap.new
    end

    # The windows using this provider (Window#storage_provider registers them):
    # a change one makes is broadcast to the others of the same origin.
    def register(window)
      @windows[window] = true
      nil
    end

    def windows
      list = []
      @windows.each_key { |window| list << window }
      list
    end

    def local_area(origin) = (@local[origin.to_s] ||= StorageArea.new)
    def session_area(origin) = (@session[origin.to_s] ||= StorageArea.new)

    # The session of a new top-level browsing context this session opens (a
    # popup): the same local areas, and so the same windows to tell of a
    # change to one, and a copy of each session area as it is now — later
    # changes on either side stay on that side.
    def new_session
      StorageProvider.new.__internal_branch_from__(@local, @session, @windows)
    end

    def __internal_branch_from__(local, session, windows)
      @local = local
      @windows = windows
      session.each { |origin, area| @session[origin] = area.copy }
      self
    end
  end

  # One storage area: the key/value map the windows of a session share.
  class StorageArea
    attr_reader :map

    def initialize(map = {})
      @map = map
    end

    def copy = StorageArea.new(@map.dup)
  end

  # `Storage` — the object behind `localStorage` / `sessionStorage`. Mirrors the
  # Web Storage API: `getItem(key)`, `setItem(key, value)`, `removeItem(key)`,
  # `clear()`, `key(index)`, `length`. Values are coerced to String (a browser
  # stores everything as a string).
  #
  # Its entries live in a StorageArea, which a window shares with the other
  # windows of its browsing session (see StorageProvider). A change made through
  # one Storage object fires a `storage` event, from a task, at every OTHER
  # window bound to the same area. A Storage built with no arguments has a
  # private area of its own.
  class Storage
    include Enumerable

    def initialize(window = nil, area = nil, kind = nil)
      @window = window
      @area = area || StorageArea.new
      @kind = kind
      @store = @area.map
    end

    attr_reader :window

    def __internal_area__ = @area

    # Ruby-idiomatic facade matching `Object.keys(storage)` /
    # `Object.values(storage)` / `Object.entries(storage)` semantics
    # that user code reaches for in browser JS.

    def keys
      @store.keys
    end

    def values
      @store.values
    end

    def entries
      @store.to_a
    end

    def to_h
      @store.dup
    end

    def each(&blk)
      @store.each(&blk)
    end

    def length
      @store.size
    end

    alias size length

    def get_item(key)
      @store[web_string(key)]
    end

    def set_item(key, value)
      store_item(web_string(key), web_string(value))
    end

    def remove_item(key)
      delete_item(web_string(key))
    end

    def clear
      clear_items
    end

    def key(index)
      @store.keys[to_index(index)]
    end

    def [](key)
      @store[web_string(key)]
    end

    def []=(key, value)
      store_item(web_string(key), web_string(value))
    end

    def __js_get__(key)
      case key
      when "length"
        @store.size
      else
        # A named-property miss is JS `undefined` (and `"k" in storage` false).
        @store.key?(key.to_s) ? @store[key.to_s] : Bridge::ABSENT
      end
    end

    # Named setter: the proxy key is already a String; the value is ToString-
    # coerced JS-side (WebIDL DOMString named setter) before crossing.
    def __js_set__(key, value)
      store_item(key.to_s, value.to_s)
    end

    # Named deleter (`delete storage[key]`): the browser's Storage removes the
    # entry. Always "succeeds" so the JS `delete` returns true.
    def __js_delete__(key)
      delete_item(key.to_s)
      true
    end

    # WebIDL "supported property names": the current keys, so `Object.keys` /
    # `for…in` / spread enumerate only the stored entries (not the builtins,
    # which live on Storage.prototype).
    def __js_named_props__
      @store.keys
    end

    include Bridge::Methods
    js_methods %w[getItem setItem removeItem clear key]
    def __js_call__(method, args)
      case method
      when "getItem"
        require_args!(method, args, 1)
        @store[web_string(args[0])]
      when "setItem"
        require_args!(method, args, 2)
        store_item(web_string(args[0]), web_string(args[1]))
      when "removeItem"
        require_args!(method, args, 1)
        delete_item(web_string(args[0]))
      when "clear"
        clear_items
      when "key"
        require_args!(method, args, 1)
        @store.keys[to_index(args[0])]
      end
    end

    private

    def store_item(key, value)
      old = @store[key]
      @store[key] = value
      broadcast(key, old, value) unless old == value
      nil
    end

    def delete_item(key)
      return nil unless @store.key?(key)

      old = @store.delete(key)
      broadcast(key, old, nil)
      nil
    end

    def clear_items
      return nil if @store.empty?

      @store.clear
      broadcast(nil, nil, nil)
      nil
    end

    # HTML "broadcast": queue a `storage` event at every OTHER window whose
    # Storage object of this kind shares this area — the same origin, and the
    # same session for sessionStorage — and whose document is fully active. `url` is the URL of the
    # document that made the change; `storageArea` is the receiving window's own
    # Storage object.
    def broadcast(key, old_value, new_value)
      return unless @window

      url = @window.location&.href.to_s
      provider = @window.storage_provider
      origin = @window.origin
      provider.windows.each do |target|
        next if target.equal?(@window)
        next unless target.__internal_fully_active__? && target.origin == origin

        storage = @kind == "sessionStorage" ? target.session_storage : target.local_storage
        next unless storage.__internal_area__.equal?(@area)

        target.scheduler.set_timeout(proc do
          next unless target.__internal_fully_active__?

          event = StorageEvent.new("storage", "key" => key, "oldValue" => old_value, "newValue" => new_value,
            "url" => url, "storageArea" => storage)
          target.dispatch_event(event.__internal_mark_trusted__)
        end, 0)
      end
    end

    # WebIDL DOMString coercion of a method argument: JS null → "null",
    # undefined → "undefined", everything else via ToString.
    def web_string(value)
      return "null" if value.nil?
      return "undefined" if value.equal?(Bridge::UNDEFINED)

      value.to_s
    end

    # WebIDL `unsigned long` index coercion (ToUint32): out-of-range / huge
    # indices wrap mod 2**32 (so `key(2**32)` behaves like `key(0)`), and
    # non-numeric values become 0.
    def to_index(value)
      n = value.equal?(Bridge::UNDEFINED) ? 0 : Integer(value.to_i)
      n % (1 << 32)
    rescue StandardError
      0
    end

    # A missing required argument is a TypeError (not a DOMException), matching
    # the WebIDL overload-resolution error for too few arguments.
    def require_args!(method, args, arity)
      return if args.length >= arity

      raise Bridge::TypeError,
            "Failed to execute '#{method}' on 'Storage': #{arity} argument#{"s" if arity > 1} required, " \
            "but only #{args.length} present."
    end
  end
end
