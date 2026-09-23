# frozen_string_literal: true

module Dommy
  # Elements whose whole point is a state the user can change.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<dialog>` — `open` reflected boolean, `show()` / `showModal()` /
  # `close(returnValue?)`. Dommy has no modal stack, so showModal is
  # functionally identical to show (no backdrop, no escape-to-close).
  class HTMLDialogElement < HTMLElement
    reflect_boolean :open
    # Own __js_call__ methods, on top of Element's.

    def return_value
      @return_value ||= ""
    end

    def return_value=(v)
      @return_value = v.to_s
    end

    def show
      self.open = true
      nil
    end

    # `showModal()` requires the dialog to be connected and not already open;
    # otherwise it throws InvalidStateError. (Dommy has no top layer, so the
    # modal itself is functionally the same as show.)
    def show_modal
      if has_attribute?("open")
        raise DOMException::InvalidStateError, "showModal() called on an open dialog"
      end
      unless is_connected?
        raise DOMException::InvalidStateError, "showModal() called on a dialog not connected to a document"
      end

      self.open = true
      nil
    end

    # `close(returnValue?)`: abort if the dialog isn't open; otherwise clear the
    # open attribute, optionally set returnValue, and QUEUE (async) a trusted,
    # non-bubbling `close` event.
    def close(value = nil)
      return nil unless has_attribute?("open")

      self.open = false
      @return_value = value.to_s unless value.nil?
      fire = proc do
        dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
      end
      scheduler = @document.respond_to?(:default_view) && @document.default_view&.scheduler
      scheduler ? scheduler.set_timeout(fire, 0) : fire.call
      nil
    end

    def __js_get__(key)
      case key
      when "returnValue"
        return_value
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "returnValue"
        self.return_value = value
      else
        super
      end
    end

    js_methods %w[show showModal close]
    def __js_call__(method, args)
      case method
      when "show"
        show
      when "showModal"
        show_modal
      when "close"
        close(args[0])
      else
        super
      end
    end
  end

  # `<details>` — `open` reflected boolean. Whenever the open state changes —
  # via the `open` property, setAttribute/removeAttribute, or toggleAttribute —
  # a non-bubbling `toggle` event fires (per spec). Routing the dispatch through
  # the attribute mutators (not just the property setter) is what makes
  # `details.toggleAttribute("open")` fire toggle, which Stimulus's `:open`
  # action option relies on.

  # `<details>` — `open` reflected boolean. Whenever the open state changes —
  # via the `open` property, setAttribute/removeAttribute, or toggleAttribute —
  # a non-bubbling `toggle` event fires (per spec). Routing the dispatch through
  # the attribute mutators (not just the property setter) is what makes
  # `details.toggleAttribute("open")` fire toggle, which Stimulus's `:open`
  # action option relies on.
  class HTMLDetailsElement < HTMLElement
    reflect_string :name

    def open
      reflected_boolean("open")
    end

    def open=(v)
      set_reflected_boolean("open", v)
    end

    # HTML's attribute change steps for a details element.
    def __internal_attribute_changed__(name, old_value, new_value, namespace)
      return nil unless namespace.nil?

      if name.casecmp?("open")
        # A boolean attribute: its PRESENCE is the state, so a change of value
        # (`open=""` to `open="x"`) is not a toggle.
        announce_open_change(!old_value.nil?, !new_value.nil?)
      elsif name.casecmp?("name")
        # Renaming moves this element into a different exclusive group. The
        # member already open in that group keeps its state, so it is this
        # element that closes — the same rule as arriving there by insertion.
        yield_to_open_group_peer
      end
      nil
    end

    # Run the insertion steps over details elements that arrived together — a
    # parsed document, or a subtree inserted in one go. The DOM inserts nodes one
    # at a time, so each element only sees the group members that were already
    # there; that is what makes the FIRST open member of a parsed group the one
    # that stays open, while an element inserted into a settled group later is
    # the one that closes.
    def self.run_insertion_steps(elements)
      pending = elements.map(&:__dommy_backend_node__).to_set
      elements.each do |element|
        pending.delete(element.__dommy_backend_node__)
        element.__internal_details_inserted__(pending)
      end
      nil
    end

    # HTML's details insertion steps, run when the element joins a tree — and
    # for every details the parser produced, since none of them went through an
    # attribute change. Two things follow from arriving somewhere: an element the
    # parser opened owes its toggle event, and an open element joining a group
    # that already has an open member closes. `pending` holds the members of the
    # same batch that have not been inserted yet, which this element cannot see.
    def __internal_details_inserted__(pending = nil)
      queue_toggle_event(false, true) if open && !@__toggle_announced
      yield_to_open_group_peer(pending)
      nil
    end

    def __js_get__(key)
      key == "open" ? open : super
    end

    def __js_set__(key, value)
      if key == "open"
        self.open = value
      else
        super
      end
    end

    private

    def announce_open_change(was, now)
      return nil if was == now

      # This element's own toggle is queued first; only then do the other open
      # members of its exclusive group (same `name`, same tree scope) close and
      # queue theirs, so the group's events arrive in the order it settled.
      queue_toggle_event(was, now)
      close_open_group_peers if now
      nil
    end

    # WHATWG details name-group exclusivity: at most one details per (name, tree
    # scope) may be open. The other members of this element's group — details
    # elements in the same tree sharing its non-empty `name`.
    def group_peers
      group = @__node__["name"].to_s
      return [] if group.empty?

      root = get_root_node
      return [] unless root.respond_to?(:query_selector_all)

      root.query_selector_all("details").select do |other|
        other.respond_to?(:__dommy_backend_node__) &&
          !other.__dommy_backend_node__.equal?(__dommy_backend_node__) &&
          other.__dommy_backend_node__["name"].to_s == group
      end
    end

    # This element just opened: the rest of its group closes.
    def close_open_group_peers
      group_peers.each { |other| other.open = false if other.respond_to?(:open) && other.open }
    end

    # This element just joined a group: whoever was open there stays open, and
    # this element is the one that closes.
    def yield_to_open_group_peer(pending = nil)
      return unless open

      peers = group_peers
      peers = peers.reject { |other| pending.include?(other.__dommy_backend_node__) } if pending
      return unless peers.any? { |other| other.respond_to?(:open) && other.open }

      self.open = false
      nil
    end

    # WHATWG "queue a details toggle event task": the trusted ToggleEvent fires
    # asynchronously, and rapid changes coalesce into ONE event whose oldState is
    # the state before the first change and newState the state after the last.
    def queue_toggle_event(old_open, new_open)
      # A change while a toggle task is still pending CANCELS that task and
      # queues a fresh one at the back of the queue. The event still reports the
      # state before the first change and after the last, but it now arrives
      # after everything queued in between — which is what orders the events of
      # an accordion group by when each element last settled.
      @__toggle_old = old_open ? "open" : "closed" unless @__toggle_pending
      @__toggle_new = new_open ? "open" : "closed"
      @__toggle_pending = true
      @__toggle_announced = true
      generation = @__toggle_generation = (@__toggle_generation || 0) + 1
      fire = proc do
        next unless generation == @__toggle_generation

        @__toggle_pending = false
        evt = ToggleEvent.new("toggle",
          "oldState" => @__toggle_old, "newState" => @__toggle_new,
          "bubbles" => false, "cancelable" => false)
        dispatch_event(evt.__internal_mark_trusted__)
      end
      scheduler = @document.respond_to?(:__internal_scheduler__) ? @document.__internal_scheduler__ : nil
      scheduler ? scheduler.set_timeout(fire, 0) : fire.call
    end
  end

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.

  # `<slot>` — composes light DOM into the shadow tree. Light DOM
  # children of the shadow's host get assigned to slots: those whose
  # `slot=name` attribute matches a named slot, or those without a
  # `slot` attribute go to the unnamed default slot. If nothing is
  # assigned, the slot's own children render as fallback content.
  class HTMLSlotElement < HTMLElement
    reflect_string :name
    # Own __js_call__ methods, on top of Element's.

    # `slot.assignedNodes({ flatten: true|false })` — returns the
    # light DOM children currently composed into this slot. With
    # `flatten: true` and no assigned nodes, falls back to the
    # slot's own children (the default content).
    def assigned_nodes(options = nil)
      flatten = options.is_a?(Hash) ? (options["flatten"] || options[:flatten]) : false
      nodes = matching_light_nodes
      if nodes.empty? && flatten
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      else
        nodes
      end
    end

    def assigned_elements(options = nil)
      assigned_nodes(options).select { |n| n.is_a?(Element) }
    end

    # `slot.assign(...)` — manual assignment (honored only when the
    # owning shadow uses `slotAssignment: "manual"`). We accept the
    # call and fire `slotchange` in both modes; named mode simply
    # ignores the override.
    def assign(*nodes)
      @__manual_assignment = nodes.flatten.select { |n| n.respond_to?(:__dommy_backend_node__) }
      dispatch_event(Event.new("slotchange", "bubbles" => true))
      nil
    end

    def __js_get__(key)
      case key
      when "assignedNodes"
        assigned_nodes
      when "assignedElements"
        assigned_elements
      else
        super
      end
    end

    js_methods %w[assignedNodes assignedElements assign]
    def __js_call__(method, args)
      case method
      when "assignedNodes"
        assigned_nodes(args[0])
      when "assignedElements"
        assigned_elements(args[0])
      when "assign"
        assign(*args)
      else
        super
      end
    end

    private

    def matching_light_nodes
      sr = @document.__internal_shadow_root_containing__(@__node__)
      return [] unless sr

      host = sr.host
      return [] unless host

      slot_name = name
      # Manual mode honors the explicit list.
      if sr.slot_assignment == "manual" && @__manual_assignment
        return @__manual_assignment
      end

      host
        .__dommy_backend_node__
        .children
        .map do |child|
          wrapped = @document.wrap_node(child)
          next nil unless wrapped

          attr_value = child.element? ? child["slot"].to_s : ""
          if slot_name.empty?
            attr_value.empty? ? wrapped : nil
          else
            (child.element? && attr_value == slot_name) ? wrapped : nil
          end
        end
        .compact
    end
  end

  # `<select>` — exposes `value` (selected option's value), `options`,
  # `selectedIndex`, and dispatches change events. Minimal compared to
  # happy-dom's full HTMLSelectElement, but covers common test cases.

  # `<template>` — `content` returns the DocumentFragment that
  # owns the template's children. Reuses the document-level
  # template_content storage so existing template handling stays
  # consistent.
  class HTMLTemplateElement < HTMLElement
    def content
      @document.template_content_fragment(self)
    end

    def __js_get__(key)
      case key
      when "content"
        content
      else
        super
      end
    end
  end

  # `<td>` / `<th>` — single table cell. `cellIndex` is the
  # position within the parent row's cells collection.
end
