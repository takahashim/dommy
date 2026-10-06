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

    def initialize(registry:, name:, local_name:, observed_attributes:, callbacks:, disable_shadow: false)
      @registry = registry
      @name = name
      @local_name = local_name
      @observed_attributes = observed_attributes.map(&:to_s).freeze
      @callbacks = callbacks.map(&:to_s).to_set.freeze
      @disable_shadow = disable_shadow
    end

    def autonomous? = @name == @local_name

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
      data.state = "custom"
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
  # `adopted_callback`, `connected_move_callback` and
  # `attribute_changed_callback(name, old, new[, namespace])`.
  class RubyCustomElementDefinition < CustomElementDefinition
    RUBY_METHODS = {
      "connectedCallback" => :connected_callback,
      "disconnectedCallback" => :disconnected_callback,
      "connectedMoveCallback" => :connected_move_callback,
      "adoptedCallback" => :adopted_callback,
      "attributeChangedCallback" => :attribute_changed_callback
    }.freeze

    attr_reader :klass

    def initialize(registry:, name:, klass:)
      @klass = klass
      observed = klass.respond_to?(:observed_attributes) ? Array(klass.observed_attributes) : []
      callbacks = RUBY_METHODS.select { |_, method| klass.method_defined?(method) }.keys
      super(registry: registry, name: name, local_name: name, observed_attributes: observed, callbacks: callbacks)
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
      wrap_as_class(document, node, nil) do |data|
        data.definition = self
        data.state = "custom"
      end
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
    # https://html.spec.whatwg.org/#valid-custom-element-name
    # PCENChar — the characters allowed after the first (ASCII-lower) char: a
    # superset of [-._0-9a-z] plus wide Unicode ranges. A valid name is
    # `[a-z] PCENChar* - PCENChar*` (i.e. lower-alpha start + at least one "-").
    PCEN = "\\-._0-9a-z\\u00B7\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u037D" \
           "\\u037F-\\u1FFF\\u200C-\\u200D\\u203F-\\u2040\\u2070-\\u218F" \
           "\\u2C00-\\u2FEF\\u3001-\\uD7FF\\uF900-\\uFDCF\\uFDF0-\\uFFFD\\u{10000}-\\u{EFFFF}"
    NAME_RE = Regexp.new("\\A[a-z][#{PCEN}]*-[#{PCEN}]*\\z")

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
      key.match?(NAME_RE) && !RESERVED_NAMES.include?(key)
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
    def self.lookup(document, namespace, local_name)
      return nil unless namespace == Element::HTML_NAMESPACE

      for_document(document)&.definition_for_local_name(local_name)
    end

    # Register a Ruby class extending HTMLElement as the definition for
    # `name`.
    def define(name, klass, _options = nil)
      raise Bridge::TypeError, "the custom element constructor must be a class" unless klass.is_a?(Class)

      key = name.to_s
      unless key.match?(NAME_RE)
        raise DOMException::SyntaxError, "#{name.inspect} is not a valid custom element name"
      end
      if RESERVED_NAMES.include?(key)
        raise DOMException::SyntaxError, "#{name.inspect} is a reserved element name"
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

    # The autonomous definition whose local name is `local_name` (customized
    # built-ins are not modelled, so it is the one named so).
    def definition_for_local_name(local_name)
      definition = @definitions[local_name.to_s]
      definition if definition&.autonomous?
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
        Internal::CEReactions.enqueue_upgrade(element, definition) if element
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
