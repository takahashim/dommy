# frozen_string_literal: true

require_relative "../internal/toggle_events"

module Dommy
  # Elements whose whole point is a state the user can change.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<dialog>` — `open` reflected boolean, `show()` / `showModal()` /
  # `close(returnValue?)` / `requestClose(returnValue?)`, `closedBy`. Dommy
  # has no rendering of the top layer, but it keeps what scripts can
  # observe of it: a dialog shown with showModal() is modal (`:modal`), and
  # while it is the topmost one the rest of the document is inert, so the
  # focus cannot leave it. Showing a dialog moves the focus into it (the
  # dialog focusing steps) and closing it gives the focus back. Showing one
  # either way closes the auto and hint popovers it is not nested in
  # (Internal::PopoverStack).
  #
  # Opening and closing fire `beforetoggle` synchronously (before the `open`
  # attribute changes; an opening can be canceled) and `toggle` asynchronously,
  # with rapid changes coalescing into one event (Internal::ToggleEvents).
  #
  # The dialog's close watcher is modelled only as far as requestClose()
  # needs it: an open, connected dialog has one, and requesting to close it
  # fires a cancelable `cancel` and then closes the dialog. (No close
  # request — Esc, light dismiss — reaches it.)
  class HTMLDialogElement < HTMLElement
    include Internal::ToggleEvents
    reflect_boolean :open
    reflect_setter closed_by: { attr: "closedby", js: "closedBy" }

    CLOSED_BY_STATES = %w[any closerequest none].freeze
    COMMANDS = %w[close request-close show-modal].freeze

    def return_value
      @return_value ||= ""
    end

    def return_value=(v)
      @return_value = v.to_s
    end

    # The dialog's "is modal" flag, for the popover validity check.
    def __internal_modal__? = @__dialog_is_modal__ ? true : false

    # `closedBy`: the keyword of the computed closed-by state — the
    # closedby attribute's any / closerequest / none, or for its Auto state
    # (missing or invalid) closerequest while modal and none otherwise.
    def closed_by
      state = __internal_attribute_value__("closedby")&.downcase(:ascii)
      return state if CLOSED_BY_STATES.include?(state)

      __internal_modal__? ? "closerequest" : "none"
    end

    # WHATWG "show()" steps. Unlike showModal(), show() never checks
    # connectedness or the popover-showing state — only whether the dialog is
    # already open, and if so whether it is modal.
    def show
      if __internal_has_attribute__?("open")
        return nil unless @__dialog_is_modal__

        raise DOMException::InvalidStateError, "show() called on an open modal dialog"
      end

      return nil unless fire_beforetoggle(false, true)
      # A beforetoggle listener may have opened the dialog itself (from
      # within its own handler); re-check before committing to our own open.
      return nil if __internal_has_attribute__?("open")

      queue_toggle_event(dialog_toggle_tracker, false, true)
      self.open = true
      @__previously_focused_element__ = @document.__internal_focused_element__
      hide_popovers_outside
      __internal_dialog_focusing_steps__
      nil
    end

    # `showModal()`: HTML's "show a modal dialog" with no source.
    def show_modal = show_a_modal_dialog(nil)

    # `close(returnValue?)`: HTML's "close the dialog" with no source.
    def close(value = nil)
      close_the_dialog(value, nil)
    end

    # `requestClose(returnValue?)`: HTML's "request to close the dialog"
    # with no source.
    def request_close(value = nil)
      request_to_close(value.nil? || value.equal?(Bridge::UNDEFINED) ? nil : value.to_s, nil)
    end

    js_accessor :return_value

    js_methods %w[show showModal close requestClose]
    def __js_call__(method, args)
      case method
      when "show"
        show
      when "showModal"
        show_modal
      when "close"
        # `close(optional DOMString returnValue)` and requestClose: undefined
        # is a missing argument, which leaves returnValue alone.
        close(args[0].equal?(Bridge::UNDEFINED) ? nil : args[0])
      when "requestClose"
        request_close(args[0].equal?(Bridge::UNDEFINED) ? nil : args[0])
      else
        super
      end
    end

    # HTML's "is valid command steps" for dialog elements.
    def __internal_valid_command__?(command) = COMMANDS.include?(command)

    # HTML's "command steps" for dialog elements: `source` is the invoking
    # button, whose optional value becomes the return value.
    def __internal_run_command__(source, command)
      return if __internal_popover_showing__?

      open = __internal_has_attribute__?("open")
      value = source.__internal_attribute_value__("value")
      case command
      when "close" then close_the_dialog(value, source) if open
      when "request-close" then request_to_close(value, source) if open
      when "show-modal" then show_a_modal_dialog(source) unless open
      end
      nil
    end

    # HTML's dialog removing steps: a removed dialog leaves the top layer
    # and is no longer modal. (Its close watcher goes with the open
    # attribute's cleanup; Dommy derives it from the dialog's state.)
    def __internal_dialog_removed__
      @document.__internal_remove_modal_dialog__(self)
      set_modal(false)
      nil
    end

    # HTML's "dialog focusing steps": the dialog itself when it has
    # autofocus, else its focus delegate (its first sequentially focusable
    # descendant, or its autofocus one), else the dialog, takes the focus;
    # then the page's autofocus is settled.
    def __internal_dialog_focusing_steps__
      control = __internal_has_attribute__?("autofocus") ? self : nil
      control ||= Internal::Focusability.focus_delegate(self, "other")
      control ||= self
      Internal::Focusability.run_focusing_steps(control)
      @document.__internal_autofocus_done__
      nil
    end

    private

    # HTML's "show a modal dialog" given a source (the invoking button, or
    # nil). Requires the dialog to be connected, not already showing as a
    # popover, and not already open-and-non-modal; otherwise it throws
    # InvalidStateError. An already open-and-modal dialog no-ops.
    def show_a_modal_dialog(source)
      if __internal_has_attribute__?("open")
        return nil if @__dialog_is_modal__

        raise DOMException::InvalidStateError, "showModal() called on an open dialog"
      end
      unless is_connected?
        raise DOMException::InvalidStateError, "showModal() called on a dialog not connected to a document"
      end
      if popover_showing?
        raise DOMException::InvalidStateError, "showModal() called on a dialog that is showing as a popover"
      end

      return nil unless fire_beforetoggle(false, true, source)
      # A beforetoggle listener may have opened, disconnected, or
      # popover-shown the dialog itself; re-check before committing to modal.
      return nil if __internal_has_attribute__?("open") || !is_connected? || popover_showing?

      queue_toggle_event(dialog_toggle_tracker, false, true, source)
      self.open = true
      set_modal(true)
      # The document is blocked by this dialog: everything outside it is
      # inert (Internal::Focusability.inert?).
      @document.__internal_add_modal_dialog__(self)
      @__previously_focused_element__ = @document.__internal_focused_element__
      hide_popovers_outside
      __internal_dialog_focusing_steps__
      nil
    end

    # HTML's "close the dialog" with a result (nil or a string) and a
    # source: fire a non-cancelable beforetoggle, clear the open attribute
    # and the is-modal flag, set the return value, give the focus back to
    # the element focused before the dialog showed (when the focus is inside
    # it, or it was modal), and queue a trusted, non-bubbling `close`.
    def close_the_dialog(value, source)
      return nil unless __internal_has_attribute__?("open")

      fire_beforetoggle(true, false, source)
      # beforetoggle isn't cancelable here, but a listener can still close
      # the dialog itself from inside its own handler; re-check before
      # queuing our own toggle/close.
      return nil unless __internal_has_attribute__?("open")

      queue_toggle_event(dialog_toggle_tracker, true, false, source)
      self.open = false
      was_modal = __internal_modal__?
      @document.__internal_remove_modal_dialog__(self) if was_modal
      set_modal(false)
      @return_value = value.to_s unless value.nil?
      @__request_close_return_value__ = nil
      @__request_close_source__ = nil
      restore_previous_focus(was_modal)
      queue_element_task { dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false).__internal_mark_trusted__) }
      nil
    end

    def restore_previous_focus(was_modal)
      element = @__previously_focused_element__
      return if element.nil?

      @__previously_focused_element__ = nil
      focused = @document.__internal_focused_element__
      inside = focused && Internal::Retargeting.shadow_including_inclusive_ancestor?(self, focused)
      Internal::Focusability.run_focusing_steps(element) if inside || was_modal
    end

    # HTML's "request to close the dialog": request to close its close
    # watcher (which an open, connected dialog has) without requiring
    # history-action activation, so the `cancel` event can always be
    # canceled; when it is not, the dialog closes with `value` and `source`.
    def request_to_close(value, source)
      return nil unless __internal_has_attribute__?("open")
      return nil unless is_connected?
      # A close watcher running its cancel action ignores a nested request.
      return nil if @__running_cancel_action__

      @__request_close_return_value__ = value
      @__request_close_source__ = source
      @__running_cancel_action__ = true
      begin
        should_continue = dispatch_event(Event.new("cancel", "bubbles" => false, "cancelable" => true).__internal_mark_trusted__)
      ensure
        @__running_cancel_action__ = false
      end
      return nil unless should_continue

      close_the_dialog(@__request_close_return_value__, @__request_close_source__)
    end

    # Set "is modal", which :modal reads.
    def set_modal(value)
      return if @__dialog_is_modal__ == value

      @__dialog_is_modal__ = value
      @document.__internal_note_selector_state_change__
    end

    # The last steps of showing a dialog, either way: the auto and hint
    # popovers it is not nested in close — the dialog itself too, when it is
    # also showing as a popover, since it is no descendant of itself.
    def hide_popovers_outside
      stack = @document.__internal_popover_stack__
      stack.hide_popovers_until(stack.topmost_ancestor(self, nil), false, true)
    end

    # This element's own "dialog toggle task tracker" — separate from any
    # "popover toggle task tracker" the same element also has as a
    # `<dialog popover>`, so the two purposes' rapid changes coalesce
    # independently rather than merging into one event.
    def dialog_toggle_tracker
      @__dialog_toggle_tracker ||= Internal::ToggleTaskTracker.new
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
    include Internal::ToggleEvents
    reflect_string :name

    def open
      reflected_boolean("open")
    end

    def open=(v)
      set_reflected_boolean("open", v)
    end

    # HTML's attribute change steps for a details element.
    def __internal_attribute_changed__(name, old_value, new_value, namespace)
      super
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
      queue_toggle_event(details_toggle_tracker, false, true) if open && !details_toggle_tracker.announced
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
      queue_toggle_event(details_toggle_tracker, was, now)
      close_open_group_peers if now
      nil
    end

    # This element's own "details toggle task tracker" — separate from any
    # "popover toggle task tracker" the same element also has as a
    # `<details popover>`, so the two purposes' rapid changes coalesce
    # independently rather than merging into one event.
    def details_toggle_tracker
      @__details_toggle_tracker ||= Internal::ToggleTaskTracker.new
    end

    # WHATWG details name-group exclusivity: at most one details per (name, tree
    # scope) may be open. The other members of this element's group — details
    # elements in the same tree sharing its non-empty `name`.
    def group_peers
      group = __internal_attribute_value__("name").to_s
      return [] if group.empty?

      root = get_root_node
      return [] unless root.respond_to?(:query_selector_all)

      root.query_selector_all("details").select do |other|
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
      @__manual_assignment = nodes.flatten.select { |n| n.is_a?(Node) && n.__dommy_backend_node__ }
      dispatch_event(Event.new("slotchange", "bubbles" => true))
      nil
    end

    js_readable :assigned_nodes, :assigned_elements

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

          attr_value = child.element? ? Backend.no_namespace_attribute_value(child, "slot").to_s : ""
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
    # Declarative shadow DOM's `for` attribute, reflected as a plain string
    # (unrelated to the DOMTokenList `output.htmlFor` is).
    reflect_string html_for: { attr: "for", js: "htmlFor" }
    # The declarative shadow root attributes. shadowrootmode's missing and
    # invalid value default is the None state, which has no keyword (reads
    # ""); shadowrootslotassignment's is Named.
    reflect_enumerated shadow_root_mode: { attr: "shadowrootmode", keywords: %w[open closed],
                                           missing: nil, invalid: nil },
                       shadow_root_slot_assignment: { attr: "shadowrootslotassignment",
                                                      keywords: %w[named manual],
                                                      missing: "named", invalid: "named" }
    reflect_boolean shadow_root_delegates_focus: "shadowrootdelegatesfocus",
                    shadow_root_serializable: "shadowrootserializable",
                    shadow_root_clonable: "shadowrootclonable"
    reflect_string shadow_root_custom_element_registry: "shadowrootcustomelementregistry"

    def content
      @document.template_content_fragment(self)
    end

    js_readable :content
  end

  # `<td>` / `<th>` — single table cell. `cellIndex` is the
  # position within the parent row's cells collection.
end
