# frozen_string_literal: true

module Dommy
  # A custom element definition (HTML §4.13.4): the name and local name, the
  # constructor, the observed attributes and the lifecycle callbacks a
  # registry holds for a custom element, and the steps that run them. Two
  # kinds exist: one whose constructor is a Ruby class extending
  # `HTMLElement` (RubyCustomElementDefinition, what `define` registers), and
  # one whose constructor is a page's JS class (Js::JsCustomElementDefinition).
  class CustomElementDefinition
    attr_reader :name, :local_name, :registry, :observed_attributes

    def initialize(registry:, name:, local_name:, observed_attributes:, callbacks:, disable_shadow: false,
                   disable_internals: false, form_associated: false)
      @registry = registry
      @name = name
      @local_name = local_name
      @observed_attributes = observed_attributes.map(&:to_s).freeze
      @callbacks = callbacks.map(&:to_s).to_set.freeze
      @disable_shadow = disable_shadow
      @disable_internals = disable_internals
      @form_associated = form_associated
    end

    def autonomous? = @name == @local_name

    def disable_shadow? = @disable_shadow
    def disable_internals? = @disable_internals
    def form_associated? = @form_associated

    def callback?(callback_name) = @callbacks.include?(callback_name)

    def observes?(attribute_name) = @observed_attributes.include?(attribute_name)

    # HTML "upgrade an element", given the element's custom element data.
    # Raises what the construction raised (the reaction invoker reports it).
    def upgrade(data)
      return unless %w[undefined uncustomized].include?(data.state)

      data.definition = self
      data.state = "failed"
      element = data.wrapper
      element.__internal_attribute_entries__.each do |local_name, value, namespace|
        Internal::CEReactions.enqueue_callback(element, "attributeChangedCallback", [local_name, nil, value, namespace])
      end
      Internal::CEReactions.enqueue_callback(element, "connectedCallback", []) if element.is_connected?
      begin
        if @disable_shadow && element.respond_to?(:__internal_shadow_root__) && element.__internal_shadow_root__
          raise DOMException::NotSupportedError, "the definition disables shadow, but the element has a shadow root"
        end

        data.state = "precustomized"
        construct_for_upgrade(data)
      rescue StandardError
        data.definition = nil
        data.reactions.clear
        raise
      end
      if form_associated?
        # Step 9: the form owner is reset, and the callbacks it and the
        # disabled state call for are enqueued.
        form = element.__internal_form_owner__
        disabled = element.__internal_has_attribute__?("disabled") || element.disabled_by_ancestor_fieldset?
        data.form_owner = form
        data.disabled = disabled
        Internal::CEReactions.enqueue_callback(element, "formAssociatedCallback", [form]) if form
        Internal::CEReactions.enqueue_callback(element, "formDisabledCallback", [true]) if disabled
      end
      mark_custom(data)
    end

    # The element is custom now: its state says so, and an element of a
    # form-associated definition takes on a form control's constraint
    # validation surface.
    def mark_custom(data)
      data.definition = self
      data.state = "custom"
      element = data.wrapper
      element.extend(Internal::FormAssociatedCustomElements::Behavior) if form_associated? && element.is_a?(HTMLElement)
      data
    end

    # WHATWG "report an exception" for the definition's constructor's global.
    def report(error)
      window = registry&.window
      return unless window.respond_to?(:__internal_report_exception__)

      Internal::ExceptionReport.report_at(window, error)
    end
  end

  # A definition whose constructor is a Ruby class extending HTMLElement. Its
  # elements ARE instances of the class: constructing one wraps the node as
  # the class (and calls its `construct`, when it has one), and the callbacks
  # are its methods — `connected_callback`, `disconnected_callback`,
  # `adopted_callback`, `connected_move_callback`,
  # `attribute_changed_callback(name, old, new[, namespace])` and the
  # form-associated ones (`form_associated_callback(form)`,
  # `form_disabled_callback(disabled)`, `form_reset_callback`). The class
  # methods `observed_attributes`, `disabled_features` and
  # `form_associated` stand for the JS statics.
  class RubyCustomElementDefinition < CustomElementDefinition
    RUBY_METHODS = {
      "connectedCallback" => :connected_callback,
      "disconnectedCallback" => :disconnected_callback,
      "connectedMoveCallback" => :connected_move_callback,
      "adoptedCallback" => :adopted_callback,
      "attributeChangedCallback" => :attribute_changed_callback,
      "formAssociatedCallback" => :form_associated_callback,
      "formResetCallback" => :form_reset_callback,
      "formDisabledCallback" => :form_disabled_callback
    }.freeze

    attr_reader :klass

    def initialize(registry:, name:, klass:)
      @klass = klass
      observed = klass.respond_to?(:observed_attributes) ? Array(klass.observed_attributes) : []
      callbacks = RUBY_METHODS.select { |_, method| klass.method_defined?(method) }.keys
      disabled = klass.respond_to?(:disabled_features) ? Array(klass.disabled_features).map(&:to_s) : []
      super(registry: registry, name: name, local_name: name, observed_attributes: observed, callbacks: callbacks,
            disable_shadow: disabled.include?("shadow"), disable_internals: disabled.include?("internals"),
            form_associated: klass.respond_to?(:form_associated) && klass.form_associated ? true : false)
    end

    def constructor = @klass

    def invoke(element, callback_name, args)
      method = RUBY_METHODS.fetch(callback_name)
      return unless element.respond_to?(method)

      if callback_name == "attributeChangedCallback"
        # The 4th argument (the attribute's namespace) only reaches a callback
        # that takes it, so a 3-argument one keeps working.
        arity = element.method(method).arity
        args = args.first(3) unless arity.negative? || arity >= 4
      end
      element.public_send(method, *args)
    end

    # "Create an element" with the synchronous custom elements flag: a fresh
    # node wrapped as the class.
    def construct_synchronously(document)
      node = Backend.create_element(@local_name, Element::HTML_NAMESPACE, document.backend_doc)
      wrap_as_class(document, node, nil) { |data| mark_custom(data) }
    end

    private

    # Re-wrap the node as the class, handing the element's data on to the new
    # wrapper, which is told which wrapper it replaces.
    def construct_for_upgrade(data)
      previous = data.wrapper
      wrap_as_class(previous.owner_document, previous.__dommy_backend_node__, data) { nil }
    end

    def wrap_as_class(document, node, data)
      previous = document.__internal_peek_wrapper__(node)
      document.__internal_reset_wrapper__(node)
      instance = @klass.new(document, node)
      document.__internal_register_wrapper__(node, instance)
      instance.__internal_adopt_ce_data__(data) if data
      yield instance.__internal_ce_data__
      instance.__internal_upgraded_from__(previous) if previous && instance.respond_to?(:__internal_upgraded_from__)
      instance.construct if instance.respond_to?(:construct)
      instance
    end
  end

  # `window.customElements` — the window's CustomElementRegistry: custom
  # element definitions by name.
  #
  # From Ruby, `define(name, klass)` registers a Ruby class (see
  # RubyCustomElementDefinition); a page's `customElements.define(name,
  # JSClass)` registers a JS definition through the bridge. Either way the
  # elements already in the document with that name are upgraded, and the
  # reactions (constructor, connected/disconnected/adopted/attributeChanged
  # callbacks) run through Internal::CEReactions.
  #
  # Names must be valid custom element names (lower-case, with a hyphen, e.g.
  # `my-button`).
  class CustomElementRegistry
    # https://html.spec.whatwg.org/#valid-custom-element-name — a valid element
    # local name (DOM) whose first code point is an ASCII lower alpha (so the
    # rest may be anything but ASCII whitespace, NULL, "/" and ">"), with no
    # ASCII upper alpha and at least one "-".
    NAME_RE = %r{\A[a-z][^\t\n\f\r \0/>A-Z]*\z}

    # Hyphenated names that the HTML spec reserves (SVG / MathML elements), so
    # they are NOT valid custom element names even though they match NAME_RE.
    RESERVED_NAMES = %w[
      annotation-xml color-profile font-face font-face-src font-face-uri
      font-face-format font-face-name missing-glyph
    ].to_set.freeze

    attr_reader :window

    def initialize(window)
      @window = window
      # name → definition
      @definitions = {}
      # name → Array<PromiseValue>
      @pending_promises = {}
    end

    # Whether `name` is a valid custom element name. Also consulted by
    # `element_class_for`: an unrecognized HTML-namespace name that is valid here
    # is an *undefined custom element* (interface HTMLElement), not an unknown
    # element (HTMLUnknownElement).
    def self.valid_name?(name)
      key = name.to_s
      key.match?(NAME_RE) && key.include?("-") && !RESERVED_NAMES.include?(key)
    end

    # The registry `document` looks definitions up in: its window's, when it
    # has a browsing context, else none (a template's contents, a document
    # made by createHTMLDocument or DOMParser).
    def self.for_document(document)
      window = document.default_view if document.respond_to?(:default_view)
      window.custom_elements if window.respond_to?(:custom_elements)
    end

    # HTML "look up a custom element definition" for an element of the given
    # namespace and local name created in (or inserted into) `document`.
    def self.lookup(document, namespace, local_name, is_value = nil)
      return nil unless namespace == Element::HTML_NAMESPACE

      for_document(document)&.lookup_definition(local_name, is_value)
    end

    # Register a Ruby class extending HTMLElement as the definition for
    # `name`.
    def define(name, klass, _options = nil)
      raise Bridge::TypeError, "the custom element constructor must be a class" unless klass.is_a?(Class)

      key = name.to_s
      unless CustomElementRegistry.valid_name?(key)
        raise DOMException::SyntaxError, "#{name.inspect} is not a valid custom element name"
      end

      raise DOMException::NotSupportedError, "#{key} already defined" if @definitions.key?(key)

      __internal_add_definition__(RubyCustomElementDefinition.new(registry: self, name: key, klass: klass))
      nil
    end

    # The define() steps after the definition is made (its checks are the
    # caller's): append it, enqueue an upgrade for each element of the
    # document it applies to, and resolve whenDefined(). A [CEReactions]
    # member, so the upgrades have run when it returns.
    def __internal_add_definition__(definition)
      Internal::FormAssociatedCustomElements.register(definition)
      Internal::CEReactions.scope do
        @definitions[definition.name] = definition
        upgrade_particular_elements(definition)
        resolve_pending(definition.name, definition.constructor)
      end
      nil
    end

    # The constructor defined for `name`, or nil.
    def get(name)
      @definitions[name.to_s]&.constructor
    end

    def get_name(klass)
      @definitions.each_value { |d| return d.name if d.constructor == klass }
      nil
    end

    def any_definitions? = !@definitions.empty?

    def definition_for(name)
      @definitions[name.to_s]
    end

    # HTML "look up a custom element definition" in this registry for an
    # HTML element: the autonomous definition named `local_name`, or else the
    # customized built-in one named `is_value` that extends `local_name`.
    def lookup_definition(local_name, is_value = nil)
      definition = @definitions[local_name.to_s]
      return definition if definition&.autonomous?
      return nil if is_value.nil?

      definition = @definitions[is_value.to_s]
      definition if definition && !definition.autonomous? && definition.local_name == local_name.to_s
    end

    # Returns a Dommy::PromiseValue that resolves with the registered
    # constructor when `name` is defined (immediately if already so).
    def when_defined(name)
      key = name.to_s
      promise = PromiseValue.new(@window)
      if (definition = @definitions[key])
        promise.fulfill(definition.constructor)
      else
        @pending_promises[key] ||= []
        @pending_promises[key] << promise
      end

      promise
    end

    # `customElements.upgrade(root)`: try to upgrade each element among
    # root's shadow-including inclusive descendants that this registry is the
    # one for, in shadow-including tree order. A [CEReactions] member.
    def upgrade(root)
      root_node = root.__dommy_backend_node__ if root.is_a?(Node)
      return nil unless root_node

      document = root.is_a?(Document) ? root : root.owner_document
      return nil unless document && CustomElementRegistry.for_document(document).equal?(self)

      Internal::CEReactions.scope do
        document.__internal_each_shadow_including_element__(root_node) do |node|
          element = document.wrap_node(node)
          document.__internal_try_to_upgrade__(element) if element
        end
      end
      nil
    end

    # The registry's operations are JS-side (host_runtime.js: its definitions'
    # constructors and callbacks are JS functions), on the
    # CustomElementRegistry prototype; the host object answers no property.
    def __js_get__(_key)
      Bridge::ABSENT
    end

    private

    def resolve_pending(name, constructor)
      list = @pending_promises.delete(name)
      list&.each { |p| p.fulfill(constructor) }
    end

    # HTML "upgrade particular elements within a document": every element
    # among the document's shadow-including descendants in the HTML namespace
    # with the definition's local name, in shadow-including tree order. (A
    # spec-valid custom element name may contain "." or other CSS selector
    # metacharacters, so this matches local names rather than querying.)
    def upgrade_particular_elements(definition)
      document = @window.document if @window.respond_to?(:document)
      return unless document

      document.__internal_each_shadow_including_element__(document.backend_doc) do |node|
        next unless node.name == definition.local_name && Backend.namespace_uri(node) == Element::HTML_NAMESPACE

        element = document.wrap_node(node)
        next unless element
        next unless definition.autonomous? || element.__internal_is_value__ == definition.name

        Internal::CEReactions.enqueue_upgrade(element, definition)
      end
    end
  end
end

# The composite operations Ruby callers reach directly, made [CEReactions]
# (see Internal::CEReactions.scoped): markup parsed and inserted, a subtree
# cloned or imported, a node adopted.
Dommy::Internal::CEReactions.scoped(Dommy::Element, :inner_html=, :outer_html=, :insert_adjacent_html, :clone_node)
Dommy::Internal::CEReactions.scoped(Dommy::ShadowRoot, :inner_html=)
Dommy::Internal::CEReactions.scoped(Dommy::Fragment, :clone_node)
Dommy::Internal::CEReactions.scoped(Dommy::Document, :import_node, :adopt_node, :write, :writeln)
