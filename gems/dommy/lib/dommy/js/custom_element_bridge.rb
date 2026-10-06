# frozen_string_literal: true

module Dommy
  module Js
    # A custom element definition a page made with `customElements.define(name,
    # JSClass)`. Its constructor and lifecycle callbacks are JS functions the
    # JS half of the registry keeps under the definition's id (host_runtime.js
    # ceConstruct / ceUpgrade / ceInvoke); this runs them through the bridge.
    class JsCustomElementDefinition < CustomElementDefinition
      attr_reader :id

      def initialize(bridge:, id:, **attrs)
        @bridge = bridge
        @id = id
        super(**attrs)
      end

      # The constructor lives JS-side; Ruby has no handle on it.
      def constructor = nil

      def invoke(element, callback_name, args)
        @bridge.ce_invoke(@id, element, callback_name, args)
      end

      # The constructor's result, whatever it is (the caller checks it).
      def construct_synchronously(_document)
        @bridge.ce_construct(@id)
      end

      private

      def construct_for_upgrade(data)
        @bridge.ce_upgrade(@id, data.wrapper)
      end
    end

    # The Ruby half of the JS custom element registry: makes a registry's JS
    # definitions known to it (so its elements are upgraded and get their
    # reactions), and mints the element the HTML element constructor returns
    # for `new MyElement()`.
    #
    # Named distinctly from Dommy::CustomElementRegistry (the DOM
    # window.customElements registry); this is the JS<->Dommy wiring, not the
    # registry itself.
    class CustomElementBridge
      attr_writer :window

      def initialize(bridge)
        @bridge = bridge
        @window = nil
        # id → JsCustomElementDefinition
        @definitions = {}
      end

      # customElements.define()'s steps from "append definition" on: the JS
      # half made the checks and read the callbacks.
      def define(registry, id, name, local_name, observed, callbacks, disabled_features: [], form_associated: false)
        return unless registry.is_a?(CustomElementRegistry)

        disabled = Array(disabled_features).map(&:to_s)
        definition = JsCustomElementDefinition.new(
          bridge: @bridge, id: id, registry: registry, name: name.to_s, local_name: local_name.to_s,
          observed_attributes: observed, callbacks: callbacks, disable_shadow: disabled.include?("shadow"),
          disable_internals: disabled.include?("internals"), form_associated: form_associated ? true : false
        )
        @definitions[id] = definition
        registry.__internal_add_definition__(definition)
      end

      # The HTML element constructor with an empty construction stack: a new
      # element in the definition's window's document, custom from the start.
      def create(id)
        definition = @definitions[id]
        document = definition&.registry&.window&.document
        return nil unless document

        document.__internal_create_custom_element__(definition)
      end
    end
  end
end
