# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's event handlers (§8.1.8): the pieces EventTarget's handler map is
    # made of, and the attribute change steps that keep an element's event
    # handler content attributes and its handlers in sync.
    module EventHandlers
      # The tables come from the specs' IDL (event_handler_tables.rb, generated
      # by script/build_event_handlers.rb).
      #
      # GlobalEventHandlers: an event handler content attribute on every HTML,
      # SVG and MathML element.
      GLOBAL = EventHandlerTables::GLOBAL_EVENT_HANDLERS

      # WindowEventHandlers: content attributes of body and frameset only.
      WINDOW = EventHandlerTables::WINDOW_EVENT_HANDLERS

      # The Window-reflecting body element event handler set, plus the
      # WindowEventHandlers: on body/frameset these are the Window's handlers.
      BODY_REFLECTED = (WINDOW | EventHandlerTables::WINDOW_REFLECTING_BODY_ELEMENT_SET).freeze

      # Every event handler content attribute name, whichever element has it.
      CONTENT_ATTRIBUTES = (GLOBAL | WINDOW).freeze

      # An event handler's value while its content attribute has not been
      # compiled yet: the script body, and the element whose attribute it is
      # (nil when the handler belongs to the Window, which has no element in
      # its scope chain).
      RawHandler = Struct.new(:source, :element)

      # The listener an activated event handler registers: one per handler,
      # kept for as long as the handler is active, so changing the handler's
      # value does not move it in the event listener list.
      Listener = Struct.new(:name)

      # Extended by the classes whose bridge answers every event handler IDL
      # attribute their interface chain declares (through idl_attribute?), so
      # what they answer can be read off the class: the WebIDL audit and
      # script/build_webidl_members.rb put those attributes on the prototypes.
      module AnswersIdlAttributes
        def event_handler_idl_attributes = EventHandlers.idl_attribute_names(self)
      end

      module_function

      @idl_names_by_class = {}

      # The event handler IDL attributes instances of `klass` have: those the
      # interfaces of its chain declare (Element's onfullscreenchange,
      # HTMLElement's GlobalEventHandlers, HTMLBodyElement's
      # WindowEventHandlers, …). A name outside them is not an event handler on
      # such an object (`div.onbogus`, `div.onClick`), just an expando.
      def idl_attribute_names(klass)
        @idl_names_by_class[klass] ||= Dommy::Js::DomInterfaces.class_chain(klass).each_with_object(Set.new) do |interface, names|
          names.merge(EventHandlerTables::BY_INTERFACE.fetch(interface, []))
        end.freeze
      end

      # Whether `key` names an event handler IDL attribute of `target`.
      def idl_attribute?(target, key)
        key.is_a?(String) && key.start_with?("on") && idl_attribute_names(target.class).include?(key)
      end

      # The event handler event type of the handler called `name` (HTML
      # §8.1.8.2): the name without "on", except for the four WebKit-prefixed
      # legacy handlers.
      def event_type(name)
        EventHandlerTables::EVENT_TYPE_OVERRIDES.fetch(name) { name.delete_prefix("on") }
      end

      # Whether `name` is an event handler content attribute on `element`: an
      # event handler of the element's interface (HTML, SVG and MathML elements
      # have GlobalEventHandlers; body and frameset WindowEventHandlers too)
      # that HTML makes a content attribute — Element's onfullscreenchange is
      # an IDL attribute only, and an element in no such namespace has none.
      def content_attribute?(element, name)
        CONTENT_ATTRIBUTES.include?(name) && idl_attribute_names(element.class).include?(name)
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
        event_name = event_type(name)
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
