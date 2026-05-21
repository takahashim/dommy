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
    end

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
      matcher = Internal::ObserverMatcher.new
      @observed.find do |entry|
        observed_wrapped = entry[:target]
        next false unless observed_wrapped

        if observed_wrapped.is_a?(Document)
          matcher.matches_document?(target_wrapped, subtree: entry[:subtree])
        else
          matcher.matches?(observed_wrapped, target_wrapped, subtree: entry[:subtree])
        end
      end
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
      attrs_implied = !attribute_filter.nil? || truthy_option(opts, "attributeOldValue")
      char_implied = truthy_option(opts, "characterDataOldValue")
      attributes_on = truthy_option(opts, "attributes") || attrs_implied
      child_list_on = truthy_option(opts, "childList")
      character_data_on = truthy_option(opts, "characterData") || char_implied

      # Per spec, observe() must request at least one of childList,
      # attributes, or characterData; otherwise TypeError.
      unless child_list_on || attributes_on || character_data_on
        raise TypeError, "MutationObserver.observe: at least one of childList, attributes, characterData must be true"
      end

      @observed <<
        {
          target: target,
          child_list: child_list_on,
          subtree: truthy_option(opts, "subtree"),
          attributes: attributes_on,
          attribute_filter: attribute_filter,
          attribute_old_value: truthy_option(opts, "attributeOldValue"),
          character_data: character_data_on,
          character_data_old_value: truthy_option(opts, "characterDataOldValue")
        }
      @document.register_observer(self)
      nil
    end

    def disconnect
      @records.clear
      @scheduled = false
      @observed.clear
      @document.unregister_observer(self)
      nil
    end

    def take_records
      out = @records.dup
      @records.clear
      @scheduled = false
      out
    end

    def flush
      @scheduled = false
      return if @records.empty?

      records = @records.dup
      @records.clear
      if @callback.respond_to?(:__js_call__)
        @callback.__js_call__("call", [records])
      elsif @callback.respond_to?(:call)
        @callback.call(records)
      end
    end

    def truthy_option(hash, key)
      value = hash[key] || hash[key.to_sym]
      value == true || value.to_s == "true"
    end
  end
end
