# frozen_string_literal: true

module Dommy
  module Internal
    # Coordinates mutation notification to observers and custom element lifecycle callbacks.
    # Isolates mutation observation and custom element logic from Document's public API.
    class MutationCoordinator
      def initialize(document, observer_manager)
        @document = document
        @observer_manager = observer_manager
      end

      def register_observer(observer)
        @observer_manager.register(observer)
        nil
      end

      def unregister_observer(observer)
        @observer_manager.unregister(observer)
        nil
      end

      # Fire CustomElement lifecycle: connected (synchronous, before mutation delivery)
      def notify_connected(element)
        return unless element&.respond_to?(:connected_callback)

        element.connected_callback
      rescue StandardError
        nil
      end

      def notify_disconnected(element)
        return unless element&.respond_to?(:disconnected_callback)

        element.disconnected_callback
      rescue StandardError
        nil
      end

      # Walk a subtree and fire connected/disconnected callbacks for all elements
      def notify_connected_subtree(nk)
        return unless nk.respond_to?(:element?)

        if nk.element?
          wrapped = @document.wrap_node(nk)
          if wrapped
            notify_connected(wrapped)
            run_connected_script(wrapped)
            fire_blank_iframe_load(wrapped)
          end
        end

        nk.children.each { |c| notify_connected_subtree(c) } if nk.respond_to?(:children)
      end

      # A srcless ("blank"/about:blank) `<iframe>` connected to the document gets
      # an empty nested browsing context (a real, complete content document) and
      # fires its `load` event ASYNCHRONOUSLY (a microtask), like a real browser —
      # handlers are commonly attached after insertion (`appendChild(f); f.onload
      # = …`). Without this, code that awaits a blank iframe's load and then reads
      # `iframe.contentWindow.document` hangs: FingerprintJS's `withIframe` (its
      # font sources) does exactly that, which hung note.com's tracking plugin and
      # its whole Nuxt hydration. A `src` iframe is left to the integration layer.
      BLANK_IFRAME_SRCS = ["", "about:blank"].freeze

      def fire_blank_iframe_load(element)
        return unless element.respond_to?(:local_name) && element.local_name == "iframe"
        return unless element.respond_to?(:is_connected?) && element.is_connected?
        return unless element.respond_to?(:src) && BLANK_IFRAME_SRCS.include?(element.src.to_s.strip)

        ensure_blank_content_document(element)
        fire = proc { element.dispatch_event(Event.new("load")) rescue nil }
        scheduler = (@document.default_view&.scheduler if @document.respond_to?(:default_view))
        scheduler ? scheduler.queue_microtask(fire) : fire.call
      rescue StandardError
        nil
      end

      # Give a blank iframe a fresh empty document (or its `srcdoc`) so
      # `contentWindow` / `contentDocument` resolve and DOM ops + measurement
      # inside it work (readyState defaults to "complete"). No-op if it already
      # has one.
      def ensure_blank_content_document(element)
        return unless element.respond_to?(:__internal_set_content_document__)
        return if element.respond_to?(:content_document) && element.content_document

        srcdoc = (element.srcdoc.to_s if element.respond_to?(:srcdoc))
        html = srcdoc.nil? || srcdoc.empty? ? "<html><head></head><body></body></html>" : srcdoc
        win = Dommy::Window.new(backend_doc: Dommy::Backend.parse(html))
        element.__internal_set_content_document__(win.document)
      end

      # A classic <script> that's now genuinely connected to this document runs:
      # an inline body through the document's script_runner (wired by the JS
      # bridge), an external `src` through external_script_runner (wired by the
      # integration layer, which fetches + runs it — webpack/Vite load on-demand
      # chunks by injecting `<script src>` this way). Gated on is_connected?
      # because this walk also fires for additions to a still-detached subtree.
      def run_connected_script(element)
        return unless element.respond_to?(:__internal_take_pending_script__) # a <script>
        return unless element.respond_to?(:is_connected?) && element.is_connected?

        if (runner = @document.script_runner) && (source = element.__internal_take_pending_script__)
          runner.call(source)
        elsif @document.external_script_runner &&
              element.respond_to?(:__internal_take_pending_src__) &&
              (src = element.__internal_take_pending_src__)
          @document.external_script_runner.call(element, src)
        end
      rescue StandardError
        nil
      end

      def notify_disconnected_subtree(nk)
        return unless nk.respond_to?(:element?)

        if nk.element?
          wrapped = @document.wrap_node(nk)
          notify_disconnected(wrapped) if wrapped
        end

        nk.children.each { |c| notify_disconnected_subtree(c) } if nk.respond_to?(:children)
      end

      def notify_attribute_changed(element, name, old_value, new_value)
        return unless element&.respond_to?(:attribute_changed_callback)

        klass = element.class
        return unless klass.respond_to?(:observed_attributes)
        return unless klass.observed_attributes.include?(name.to_s.downcase)

        element.attribute_changed_callback(name, old_value, new_value)
      rescue StandardError
        nil
      end

      # Fire MutationObserver childList records
      def notify_child_list_mutation(
        target_node:,
        added_nodes:,
        removed_nodes:,
        previous_sibling: nil,
        next_sibling: nil
      )
        @document.__internal_bump_style_generation__
        target = @document.wrap_node(target_node)
        return nil unless target
        return nil if added_nodes.empty? && removed_nodes.empty?

        wrapped_added = added_nodes.map { |node| @document.wrap_node(node) }.compact
        wrapped_removed = removed_nodes.map { |node| @document.wrap_node(node) }.compact

        # Fire Custom Element lifecycle callbacks (synchronous, before MutationObserver microtask)
        added_nodes.each { |nk| notify_connected_subtree(nk) }
        removed_nodes.each { |nk| notify_disconnected_subtree(nk) }

        # Capture previousSibling / nextSibling (the position within target)
        prev_w = previous_sibling
        next_w = next_sibling
        if (prev_w.nil? && next_w.nil?) && !added_nodes.empty?
          first_nk = added_nodes.first
          last_nk = added_nodes.last
          prev_w ||= @document.wrap_node(first_nk.previous) if first_nk.respond_to?(:previous)
          next_w ||= @document.wrap_node(last_nk.next) if last_nk.respond_to?(:next)
        end

        record = MutationRecord.new(
          type: "childList",
          target: target,
          added_nodes: wrapped_added,
          removed_nodes: wrapped_removed,
          previous_sibling: prev_w,
          next_sibling: next_w
        )
        # Only observers whose matching registration requested childList get the
        # record (an `attributes`/`characterData`-only observer must not — e.g.
        # `observe(t, {childList: false, attributes: true})`). A subtree
        # registration that matched ALSO gains a transient registered observer
        # for each removed node, so mutations within the just-removed subtree
        # (before the next microtask checkpoint) are still observed.
        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry

          observer.enqueue(record) if entry[:child_list]
          wrapped_removed.each { |removed| observer.add_transient(removed, entry) } if entry[:subtree]
        end

        nil
      end

      # Fire MutationObserver attribute records
      def notify_attribute_mutation(target_node:, attribute_name:, old_value:, namespace: nil)
        @document.__internal_bump_style_generation__
        target = @document.wrap_node(target_node)
        return nil unless target

        # A namespaced attribute keeps its local name as-is; a plain HTML
        # attribute is lower-cased.
        attr = namespace ? attribute_name.to_s : attribute_name.to_s.downcase
        new_value = target_node[attr]

        # Custom Element attributeChangedCallback (synchronous)
        notify_attribute_changed(target, attr, old_value, new_value)

        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry && entry[:attributes]

          filter = entry[:attribute_filter]
          next if filter && !filter.include?(attr)

          observer.enqueue(
            MutationRecord.new(
              type: "attributes",
              target: target,
              attribute_name: attr,
              attribute_namespace: namespace,
              old_value: entry[:attribute_old_value] ? old_value : nil
            )
          )
        end

        nil
      end

      # Fire MutationObserver characterData records
      def notify_character_data_mutation(target_node:, old_value:)
        @document.__internal_bump_style_generation__
        target = @document.wrap_node(target_node)
        return nil unless target

        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry && entry[:character_data]

          observer.enqueue(
            MutationRecord.new(
              type: "characterData",
              target: target,
              old_value: entry[:character_data_old_value] ? old_value : nil
            )
          )
        end

        nil
      end
    end
  end
end
