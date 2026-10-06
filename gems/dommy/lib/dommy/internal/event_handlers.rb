# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's event handlers (§8.1.8): the pieces EventTarget's handler map is
    # made of, and the attribute change steps that keep an element's event
    # handler content attributes and its handlers in sync.
    module EventHandlers
      # GlobalEventHandlers: an event handler content attribute on every HTML,
      # SVG and MathML element. The same names as host_runtime's
      # ELEMENT_HANDLER_ATTRIBUTES (webidl_tables.js), which a test holds the
      # two to.
      GLOBAL = %w[
        onabort onauxclick onbeforeinput onbeforetoggle onblur oncancel oncanplay
        oncanplaythrough onchange onclick onclose oncommand oncontextlost oncontextmenu
        oncontextrestored oncopy oncuechange oncut ondblclick ondrag ondragend ondragenter
        ondragleave ondragover ondragstart ondrop ondurationchange onemptied onended onerror
        onfocus onfocusin onfocusout onformdata oninput oninvalid onkeydown onkeypress onkeyup
        onload onloadeddata onloadedmetadata onloadstart onmousedown onmouseenter onmouseleave
        onmousemove onmouseout onmouseover onmouseup onpaste onpause onplay onplaying onprogress
        onratechange onreset onresize onscroll onscrollend onsecuritypolicyviolation onseeked
        onseeking onselect onselectstart onslotchange onstalled onsubmit onsuspend ontimeupdate
        ontoggle onvolumechange onwaiting onwheel onanimationstart onanimationend
        onanimationiteration ongotpointercapture onlostpointercapture onpointercancel
        onpointerdown onpointerenter onpointerleave onpointermove onpointerout onpointerover
        onpointerrawupdate onpointerup ontouchcancel ontouchend ontouchmove ontouchstart
      ].to_set.freeze

      # WindowEventHandlers: content attributes of body and frameset only
      # (webidl_tables.js's WINDOW_REFLECTED_HANDLERS).
      WINDOW = %w[
        onafterprint onbeforeprint onbeforeunload onhashchange onlanguagechange onmessage
        onmessageerror onoffline ononline onpagehide onpageshow onpopstate onrejectionhandled
        onstorage onunhandledrejection onunload
      ].to_set.freeze

      # The Window-reflecting body element event handler set, plus the
      # WindowEventHandlers: on body/frameset these are the Window's handlers.
      BODY_REFLECTED = (WINDOW | %w[onblur onerror onfocus onload onresize onscroll]).freeze

      # An event handler's value while its content attribute has not been
      # compiled yet: the script body, and the element whose attribute it is
      # (nil when the handler belongs to the Window, which has no element in
      # its scope chain).
      RawHandler = Struct.new(:source, :element)

      # The listener an activated event handler registers: one per handler,
      # kept for as long as the handler is active, so changing the handler's
      # value does not move it in the event listener list.
      Listener = Struct.new(:name)

      module_function

      # Whether `name` is an event handler content attribute on `element`.
      def content_attribute?(element, name)
        return false unless name.start_with?("on")
        return true if GLOBAL.include?(name)

        WINDOW.include?(name) && body_or_frameset?(element)
      end

      def body_or_frameset?(element)
        element.is_a?(HTMLElement) && %w[body frameset].include?(element.local_name)
      end

      # HTML "determine the target of an event handler": the Window for a
      # Window-reflecting handler on body/frameset, the element otherwise.
      def target_for(element, name)
        return element unless BODY_REFLECTED.include?(name) && body_or_frameset?(element)

        document = element.owner_document
        document.default_view if document.respond_to?(:default_view)
      end

      # The attribute change steps for event handler content attributes: a
      # removed attribute deactivates the handler, a set one makes its value a
      # raw uncompiled handler and activates it.
      def attribute_changed(element, name, value, namespace)
        return unless namespace.nil? && content_attribute?(element, name)

        target = target_for(element, name)
        return unless target.respond_to?(:__internal_set_raw_event_handler__)

        element.__internal_note_handler_attribute__(name)
        event_name = name.delete_prefix("on")
        if value.nil?
          target.__internal_deactivate_event_handler__(event_name)
        else
          target.__internal_set_raw_event_handler__(event_name, value, target.equal?(element) ? element : nil)
        end
      end

      # The handler content attributes an element was created with by a parser
      # (which runs no attribute change steps), activated as if they had just
      # been set — once per attribute.
      def activate_parsed(element)
        element.__internal_attribute_names__.each do |name|
          next if element.__internal_handler_attribute_noted__?(name)

          value = element.__internal_attribute_value__(name)
          attribute_changed(element, name, value, nil) unless value.nil?
        end
      end
    end
  end
end
