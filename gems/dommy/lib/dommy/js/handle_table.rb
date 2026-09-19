# frozen_string_literal: true

module Dommy
  module Js
    # Maps JS-facing integer handles to live Ruby objects. Engine-agnostic.
    #
    # Handles are monotonic — never reused — so a handle can never refer to two
    # different objects over the table's lifetime. That invariant is what makes
    # GC-driven #release race-free: a finalizer releasing handle N can't clobber
    # a different object that happened to get the same id.
    #
    # The same Ruby object reuses its handle while still registered (keyed by
    # object_id), so it maps to a single JS proxy (stable identity). A registry
    # entry also keeps the object reachable while JS holds a proxy for it.
    class HandleTable
      def initialize
        @by_handle = {}      # handle (Integer) -> object
        @handle_by_oid = {}  # object_id -> handle (for identity reuse)
        @next_handle = 0
      end

      def register(obj)
        oid = obj.object_id
        existing = @handle_by_oid[oid]
        return existing if existing && @by_handle[existing].equal?(obj)

        handle = (@next_handle += 1)
        @by_handle[handle] = obj
        @handle_by_oid[oid] = handle
        handle
      end

      # Point the handle `old` is registered under at `new`, and return it (nil
      # when `old` has none). A node's wrapper can be replaced while a script
      # holds the element — a custom element upgrade re-wraps it — and the JS
      # proxy is bound to its handle, so moving the handle keeps that proxy the
      # element.
      def rebind(old, new)
        handle = @handle_by_oid[old.object_id]
        return nil unless handle && @by_handle[handle].equal?(old)

        @handle_by_oid.delete(old.object_id)
        @by_handle[handle] = new
        @handle_by_oid[new.object_id] = handle
        handle
      end

      def fetch(handle)
        @by_handle.fetch(handle.to_i)
      end

      # Tolerant lookup: nil when the handle is unknown (its object was released
      # by GC, or a framework passed an invalid/never-allocated handle). Used for
      # call ARGUMENTS, where a reference to a vanished object is simply absent —
      # unlike a receiver handle, where a miss is a real error (#fetch).
      def lookup(handle)
        @by_handle[handle.to_i]
      end

      # Forget a handle (called when its JS proxy is garbage-collected). Only
      # trims the mapping; the object itself lives on via its other references.
      def release(handle)
        obj = @by_handle.delete(handle.to_i)
        return unless obj

        oid = obj.object_id
        @handle_by_oid.delete(oid) if @handle_by_oid[oid] == handle.to_i
      end

      def size
        @by_handle.size
      end
    end
  end
end
