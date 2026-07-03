# frozen_string_literal: true

require_relative "internal/observer_matcher"

module Dommy
  # MutationRecord — produced for childList, attributes, or
  # characterData mutations and delivered to the observer callback.
  # Mirrors the browser MutationRecord interface; `oldValue` is only
  # populated when the observer asked for it via `attributeOldValue`
  # / `characterDataOldValue`.
  class MutationRecord
    def initialize(
      type:,
      target:,
      added_nodes: [],
      removed_nodes: [],
      previous_sibling: nil,
      next_sibling: nil,
      attribute_name: nil,
      attribute_namespace: nil,
      old_value: nil
    )
      @type = type
      @target = target
      @added_nodes = added_nodes
      @removed_nodes = removed_nodes
      @previous_sibling = previous_sibling
      @next_sibling = next_sibling
      @attribute_name = attribute_name
      @attribute_namespace = attribute_namespace
      @old_value = old_value
    end

    attr_reader(
      :type,
      :target,
      :added_nodes,
      :removed_nodes,
      :previous_sibling,
      :next_sibling,
      :attribute_name,
      :attribute_namespace,
      :old_value
    )

    def __js_get__(key)
      case key
      when "type"
        @type
      when "target"
        @target
      when "addedNodes"
        @added_nodes
      when "removedNodes"
        @removed_nodes
      when "previousSibling"
        @previous_sibling
      when "nextSibling"
        @next_sibling
      when "attributeName"
        @attribute_name
      when "attributeNamespace"
        @attribute_namespace
      when "oldValue"
        @old_value
      else
        Bridge::ABSENT
      end
    end
  end

  class MutationObserver
    def initialize(window, callback)
      @window = window
      @document = window.document
      @callback = callback
      @observed = []
      @records = []
      @scheduled = false
      @registered_docs = []
      # Transient registered observers (WHATWG DOM): when a node is removed from
      # an observed subtree, its subtree keeps being observed until the next
      # microtask checkpoint, so mutations inside the just-removed subtree (e.g.
      # removing its children in the same task) are still recorded. Each entry is
      # { root: wrapped removed node, source: the registration that matched }.
      @transients = []
    end

    include Bridge::Methods
    js_methods %w[observe disconnect takeRecords]
    def __js_call__(method, args)
      case method
      when "observe"
        observe(args[0], args[1])
      when "disconnect"
        disconnect
      when "takeRecords"
        take_records
      end
    end

    # Matches a wrapped target against this observer's scope.
    # Called by MutationCoordinator.
    def matches_wrapped?(target_wrapped)
      find_matching_entry(target_wrapped) != nil
    end

    # Find the observer entry that matches target_wrapped.
    # Returns the entry with options (attributes, attributeFilter, etc.)
    # or nil if target doesn't match any observed scope.
    def find_matching_entry(target_wrapped)
      entry = @observed.find do |e|
        observed_wrapped = e[:target]
        next false unless observed_wrapped

        if observed_wrapped.is_a?(Document)
          Internal::ObserverMatcher.matches_document?(target_wrapped, subtree: e[:subtree])
        else
          Internal::ObserverMatcher.matches?(observed_wrapped, target_wrapped, subtree: e[:subtree])
        end
      end
      return entry if entry

      # A transient registered observer matches the removed node itself and its
      # (now-detached) descendants, with the source registration's options.
      transient = @transients.find do |t|
        root = t[:root]
        root && (root.equal?(target_wrapped) || Internal::ObserverMatcher.matches?(root, target_wrapped, subtree: true))
      end
      transient && transient[:source]
    end

    # Register a transient registered observer for a node just removed from an
    # observed subtree (see @transients). Carries the matched registration's
    # options so subsequent mutations inside the removed subtree record the same
    # types. Deduped by node identity.
    def add_transient(root_wrapped, source_entry)
      return unless root_wrapped && source_entry && source_entry[:subtree]
      return if @transients.any? { |t| t[:root].equal?(root_wrapped) }

      @transients << {root: root_wrapped, source: source_entry}
      nil
    end

    def enqueue(record)
      @records << record
      return nil if @scheduled

      @scheduled = true
      @window.scheduler.queue_microtask(proc { flush })
      nil
    end

    # Public: introspection used by linkedom-style tests that peek at
    # pending records without draining (`observer.records[0]`).
    def records
      @records.dup
    end

    private

    def observe(target, options)
      opts = options.is_a?(Hash) ? options : {}
      attribute_filter = opts["attributeFilter"] || opts[:attributeFilter]
      attribute_filter = attribute_filter.map { |s| s.to_s.downcase } if attribute_filter.is_a?(Array)
      # `attributes: true` is implied if attributeFilter / attributeOldValue
      # is supplied; `characterData: true` is implied if
      # characterDataOldValue is supplied. Matches the spec's option
      # normalization in MutationObserverInit.
      # `attributes`/`characterData` are *implied* true only when their
      # old-value/filter companion is present AND the member itself is omitted.
      # If the member is present but false, that companion is a TypeError.
      attr_present = opts.key?("attributes") || opts.key?(:attributes)
      char_present = opts.key?("characterData") || opts.key?(:characterData)
      attrs_extras = !attribute_filter.nil? || truthy_option(opts, "attributeOldValue")
      char_extras = truthy_option(opts, "characterDataOldValue")

      if attrs_extras && attr_present && !truthy_option(opts, "attributes")
        raise Bridge::TypeError, "attributeOldValue/attributeFilter requires attributes to be true"
      end
      if char_extras && char_present && !truthy_option(opts, "characterData")
        raise Bridge::TypeError, "characterDataOldValue requires characterData to be true"
      end

      attributes_on = truthy_option(opts, "attributes") || (attrs_extras && !attr_present)
      child_list_on = truthy_option(opts, "childList")
      character_data_on = truthy_option(opts, "characterData") || (char_extras && !char_present)

      # Per spec, observe() must request at least one of childList,
      # attributes, or characterData; otherwise TypeError.
      unless child_list_on || attributes_on || character_data_on
        raise Bridge::TypeError, "MutationObserver.observe: at least one of childList, attributes, characterData must be true"
      end

      entry = {
        target: target,
        child_list: child_list_on,
        subtree: truthy_option(opts, "subtree"),
        attributes: attributes_on,
        attribute_filter: attribute_filter,
        attribute_old_value: truthy_option(opts, "attributeOldValue"),
        character_data: character_data_on,
        character_data_old_value: truthy_option(opts, "characterDataOldValue")
      }

      # WHATWG MutationObserver §observe: if `target` is already
      # observed, replace the existing registration's options
      # (don't merge or stack).
      existing_index = @observed.index { |e| e[:target].equal?(target) }
      if existing_index
        @observed[existing_index] = entry
      else
        @observed << entry
      end

      # Register on the TARGET's node-document — not just the observer's own
      # document — so an observer watching a node in another document (e.g. a
      # DOMParser-created XML document) is reached by that document's mutations.
      doc = document_for_target(target)
      unless @registered_docs.include?(doc)
        doc.register_observer(self)
        @registered_docs << doc
      end
      nil
    end

    def disconnect
      @records.clear
      @scheduled = false
      @observed.clear
      @registered_docs.each { |doc| doc.unregister_observer(self) }
      @registered_docs.clear
      nil
    end

    # The node-document a target belongs to (the target itself when it is a
    # Document).
    def document_for_target(target)
      return target if target.is_a?(Dommy::Document)

      target.instance_variable_get(:@document) || @document
    end

    def take_records
      out = @records.dup
      @records.clear
      @scheduled = false
      # A microtask checkpoint ends the transient registrations' lifetime.
      @transients.clear
      out
    end

    def flush
      @scheduled = false
      @transients.clear
      return if @records.empty?

      records = @records.dup
      @records.clear
      # Per spec the callback receives (mutationRecords, observer) and is invoked
      # with `this` set to the observer.
      invoke_observer_callback(records)
    rescue StandardError => e
      # A throwing observer callback MUST NOT escape its dispatch — WHATWG says to
      # report the exception and keep notifying the other observers, and a page's
      # JS must not be derailed by it. The engine swallows this for callbacks
      # (HostBridge#invoke_callback, raising:false), but that has proven
      # engine/Ruby-version-dependent, so guard here too. Without this, one broken
      # observer (e.g. an image lazy-loader that throws on a batch of <img>
      # mutations) cascades into a blank / "something went wrong" page.
      __dommy_dump_mo_failure__(records, e) if ENV["DOMMY_MO_DEBUG"]
      nil
    end

    def invoke_observer_callback(records)
      if @callback.respond_to?(:__js_call_with_this__)
        @callback.__js_call_with_this__([records, self], self)
      elsif @callback.respond_to?(:__js_call__)
        @callback.__js_call__("call", [records, self])
      elsif @callback.respond_to?(:call)
        @callback.call(records, self)
      end
    end

    # Diagnostic only (DOMMY_MO_DEBUG=1): when a page's MutationObserver callback
    # throws, append what it was handed + the error to a log file, so an
    # otherwise-unreproducible failure (e.g. note.com's React #446 inside its
    # resource observer) can be traced to the records/DOM it choked on.
    def __dommy_dump_mo_failure__(records, error)
      path = ENV["DOMMY_MO_DEBUG"]
      path = "/tmp/dommy_mo_debug.log" if path == "1" || path.to_s.empty?
      lines = ["=== MutationObserver callback raised: #{error.class}: #{error.message.to_s[0, 200]}",
               "  observing #{@observed.size} target(s): " +
                 @observed.first(3).map { |e|
                   t = e[:target]
                   "#{t.respond_to?(:__js_get__) ? t.__js_get__("nodeName") : t.class} " \
                     "{childList:#{e[:child_list]},subtree:#{e[:subtree]},attrs:#{e[:attributes]},cdata:#{e[:character_data]}}"
                 }.inspect[0, 200],
               "  #{records.size} record(s):"]
      records.first(40).each { |r| lines << "    - #{__dommy_record_summary__(r)}" }
      (error.backtrace || []).grep(/\.js:/).first(6).each { |f| lines << "    js@ #{f[0, 140]}" }
      ::File.open(path, "a") { |f| f.puts(lines.join("\n")) }
    rescue StandardError
      nil
    end

    def __dommy_record_summary__(record)
      get = ->(key) { record.respond_to?(:__js_get__) ? record.__js_get__(key) : nil }
      name = ->(n) { n.respond_to?(:__js_get__) ? n.__js_get__("nodeName") : n.class.name }
      added = __dommy_node_names__(get.call("addedNodes"), name)
      removed = __dommy_node_names__(get.call("removedNodes"), name)
      "type=#{get.call("type")} target=#{name.call(get.call("target"))} " \
        "added=#{added.first(6).inspect} removed=#{removed.first(6).inspect} attr=#{get.call("attributeName").inspect}"
    rescue StandardError => e
      "(summary failed: #{e.class})"
    end

    def __dommy_node_names__(list, name)
      (list.respond_to?(:to_a) ? list.to_a : []).map { |n| name.call(n) }
    rescue StandardError
      []
    end

    # A MutationObserverInit member is a WebIDL `boolean`, so its value is
    # converted with JS ToBoolean — any object (e.g. `attributes: ["abc"]`) is
    # truthy; only false / 0 / "" / null / undefined / NaN are falsy.
    def truthy_option(hash, key)
      value = hash.key?(key) ? hash[key] : hash[key.to_sym]
      return false if value.nil? || value == false || value == 0 || value == ""
      return false if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)
      return false if value.is_a?(Float) && value.nan?

      true
    end
  end
end
