# frozen_string_literal: true

module Dommy
  module Js
    # Bridges JS-defined custom elements to Dommy's custom element pipeline.
    # `customElements.define(name, JSClass)` on the JS side calls in here, which
    # registers a Dommy::HTMLElement subclass for `name` whose lifecycle
    # reactions (connected/disconnected/adopted/attributeChanged) route back to
    # the JS instance through the bridge. The JS class's constructor itself runs
    # on the JS side via the construction-stack upgrade in host_runtime.js.
    #
    # Named distinctly from Dommy::CustomElementRegistry (the DOM
    # window.customElements registry); this is the JS<->Dommy wiring, not the
    # registry itself.
    class CustomElementBridge
      attr_writer :window

      def initialize(bridge)
        @bridge = bridge
        @window = nil
      end

      def define(name, observed)
        return unless @window.respond_to?(:custom_elements)

        @window.custom_elements.define(name, build_class(name, observed))
        nil
      end

      # customElements.upgrade(root): delegate to Dommy's registry so a subtree
      # attached without firing reactions gets its registered elements upgraded.
      def upgrade(root)
        return unless @window.respond_to?(:custom_elements)

        @window.custom_elements.upgrade(root)
        nil
      end

      # Direct `new MyElement()`: create a fresh, unattached backing element for a
      # registered tag (its ownerDocument is the window's document). The JS ctor
      # is already running, so the element must NOT be re-upgraded — the bridge
      # crosses it with upgrade suppressed. Returns nil when the tag is undefined.
      def create(name)
        return unless @window.respond_to?(:custom_elements)
        return unless @window.custom_elements.get(name.to_s)

        @window.document.create_element(name.to_s)
      end

      private

      # A Dommy custom element class for `name` whose reactions forward to the JS
      # instance. A fresh subclass per tag carries the bridge / name / observed
      # set as class-level attributes; the reaction methods are defined once on
      # the base (BridgedCustomElement), reading them via `self.class` — so no
      # per-registration method definition is needed.
      def build_class(name, observed)
        klass = Class.new(BridgedCustomElement)
        klass.js_bridge = @bridge
        klass.js_name = name
        klass.js_observed = observed
        klass
      end
    end

    # Base for a JS-defined custom element. Each registered tag is a subclass
    # carrying its bridge / tag name / observed attributes; the lifecycle
    # reactions (defined once here) forward to the JS instance through the
    # bridge. `__js_custom_element_name__` marks the node so the bridge upgrades
    # it on first crossing (see HostBridge interface info).
    class BridgedCustomElement < Dommy::HTMLElement
      class << self
        attr_accessor :js_bridge, :js_name, :js_observed

        def observed_attributes
          js_observed
        end
      end

      def __js_custom_element_name__
        self.class.js_name
      end

      def connected_callback
        self.class.js_bridge.invoke_lifecycle(self, "connectedCallback", [])
      end

      def disconnected_callback
        self.class.js_bridge.invoke_lifecycle(self, "disconnectedCallback", [])
      end

      def adopted_callback
        self.class.js_bridge.invoke_lifecycle(self, "adoptedCallback", [])
      end

      def attribute_changed_callback(attr, old_value, new_value, namespace = nil)
        self.class.js_bridge.invoke_lifecycle(self, "attributeChangedCallback", [attr, old_value, new_value, namespace])
      end
    end
  end
end
