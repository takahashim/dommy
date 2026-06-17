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
        raise DOMException::SyntaxError, "#{name.inspect} is not a valid custom element name"
      end
      if RESERVED_NAMES.include?(key)
        raise DOMException::SyntaxError, "#{name.inspect} is a reserved element name"
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
      return nil unless root.respond_to?(:__dommy_backend_node__)

      walk_descendants(root.__dommy_backend_node__) do |nk|
        next unless nk.element?
        next unless @definitions.key?(nk.name)

        # Force re-wrap by clearing the document's cached wrapper.
        @window.document.__internal_reset_wrapper__(nk)
        wrapped = @window.document.wrap_node(nk)
        @window.document.__internal_notify_connected__(wrapped) if wrapped
      end

      nil
    end

    def __js_get__(_key)
      Bridge::ABSENT # method-only registry; any property read is absent
    end

    include Bridge::Methods
    js_methods %w[define get whenDefined upgrade]
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
      # Match by tag name rather than interpolating `name` into a CSS selector:
      # a spec-valid custom element name may contain "." (a CSS class selector
      # char) or other metacharacters, which would corrupt the query.
      doc.backend_doc.css("*").each do |nk|
        next unless nk.name == name

        doc.__internal_reset_wrapper__(nk)
        wrapped = doc.wrap_node(nk)
        doc.__internal_notify_connected__(wrapped) if wrapped
      end
    end

    def walk_descendants(node, &blk)
      yield node
      return unless node.respond_to?(:children)

      node.children.each { |c| walk_descendants(c, &blk) }
    end
  end
end
