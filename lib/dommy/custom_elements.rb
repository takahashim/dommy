# frozen_string_literal: true

module Dommy
  # `window.customElements` — registry mapping custom element tag
  # names to Ruby classes that extend `HTMLElement`. Lifecycle
  # callbacks (`connected_callback` / `disconnected_callback` /
  # `attribute_changed_callback` / `adopted_callback`) are invoked by
  # the document's mutation pipeline when registered elements are
  # added, removed, or have observed attributes mutated.
  #
  # Names must contain a hyphen per the HTML spec (e.g., `my-button`).
  class CustomElementRegistry
    NAME_RE = /\A[a-z][a-z0-9-]*-[a-z0-9-]*\z/

    def initialize(window)
      @window = window
      # name → klass
      @definitions = {}
      # name → Array<{ resolve, reject }>
      @pending_promises = {}
    end

    def define(name, klass, _options = nil)
      key = name.to_s
      unless key.match?(NAME_RE)
        raise DOMException::SyntaxError, "name must be a hyphenated string, got #{name.inspect}"
      end

      raise DOMException::NotSupportedError, "#{key} already defined" if @definitions.key?(key)

      @definitions[key] = klass
      # Resolve any pending whenDefined() promises and re-wrap
      # already-existing nodes (upgrade).
      resolve_pending(key, klass)
      upgrade_existing(key)
      nil
    end

    def get(name)
      @definitions[name.to_s]
    end

    def get_name(klass)
      @definitions.each { |k, v| return k if v == klass }
      nil
    end

    # Returns a Dommy::PromiseValue that resolves with the registered
    # constructor when `name` is defined (immediately if already so).
    def when_defined(name)
      key = name.to_s
      promise = PromiseValue.new(@window)
      if (klass = @definitions[key])
        promise.fulfill(klass)
      else
        @pending_promises[key] ||= []
        @pending_promises[key] << promise
      end

      promise
    end

    # Walk `root`'s subtree and re-wrap any nodes whose tag is now
    # registered; fires `connectedCallback` for each upgraded node
    # that's currently attached to a document tree.
    def upgrade(root)
      return nil unless root.respond_to?(:__node__)

      walk_descendants(root.__node__) do |nk|
        next unless nk.element?
        next unless @definitions.key?(nk.name)

        # Force re-wrap by clearing the document's cached wrapper.
        @window.document.__reset_wrapper__(nk)
        wrapped = @window.document.wrap_node(nk)
        @window.document.__notify_connected__(wrapped) if wrapped
      end

      nil
    end

    def __js_get__(_key)
      nil
    end

    def __js_call__(method, args)
      case method
      when "define"
        define(args[0], args[1], args[2])
      when "get"
        get(args[0])
      when "whenDefined"
        when_defined(args[0])
      when "upgrade"
        upgrade(args[0])
      end
    end

    private

    def resolve_pending(name, klass)
      list = @pending_promises.delete(name)
      list&.each { |p| p.fulfill(klass) }
    end

    # When define() lands after the matching element is already in
    # the document, those nodes need upgrading: re-wrap them with the
    # new class and fire connectedCallback.
    def upgrade_existing(name)
      doc = @window.document
      doc.nokogiri_doc.css(name).each do |nk|
        doc.__reset_wrapper__(nk)
        wrapped = doc.wrap_node(nk)
        doc.__notify_connected__(wrapped) if wrapped
      end
    end

    def walk_descendants(node, &blk)
      yield node
      return unless node.respond_to?(:children)

      node.children.each { |c| walk_descendants(c, &blk) }
    end
  end
end
