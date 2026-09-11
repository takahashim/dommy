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
          # A script-inserted INLINE classic script runs synchronously on insertion.
          runner.call(source)
        elsif @document.external_script_runner &&
              element.respond_to?(:__internal_take_pending_src__) &&
              (src = element.__internal_take_pending_src__)
          run_external_connected_script(element, src)
        end
      rescue StandardError
        nil
      end

      # A script-inserted EXTERNAL `<script src>` loads and runs ASYNCHRONOUSLY
      # (per HTML spec), unlike an inline one. Running it synchronously inside the
      # insertion steps would (a) execute it mid-render and, worse, (b) make the
      # engine drain its microtask queue while JS is still on the stack — running
      # an unrelated queued microtask (e.g. Vue's `nextTick` scheduler flush)
      # re-entrantly and patching a half-built component tree (note.com's
      # RecommendTemplate crashed Vue's `isPatchable` this way). Defer to a
      # microtask so it runs at a proper checkpoint, after the current task
      # unwinds. Re-check connectedness then (the node may have been removed).
      def run_external_connected_script(element, src)
        run = proc do
          next unless element.respond_to?(:is_connected?) && element.is_connected?

          @document.external_script_runner.call(element, src)
        rescue StandardError
          nil
        end
        scheduler = (@document.default_view&.scheduler if @document.respond_to?(:default_view))
        scheduler ? scheduler.queue_microtask(run) : run.call
      end

      def notify_disconnected_subtree(nk)
        return unless nk.respond_to?(:element?)

        if nk.element?
          wrapped = @document.wrap_node(nk)
          notify_disconnected(wrapped) if wrapped
        end

        nk.children.each { |c| notify_disconnected_subtree(c) } if nk.respond_to?(:children)
      end

      def notify_attribute_changed(element, name, old_value, new_value, namespace = nil)
        return unless element&.respond_to?(:attribute_changed_callback)

        klass = element.class
        return unless klass.respond_to?(:observed_attributes)
        return unless klass.observed_attributes.include?(name.to_s.downcase)

        # attributeChangedCallback's 4th arg is the attribute's namespace (null
        # for a plain HTML attribute). Pass it only to callbacks that accept it
        # (the JS bridge, or a 4-arg Ruby callback) so existing 3-arg Ruby custom
        # elements keep working.
        cb = element.method(:attribute_changed_callback)
        if cb.arity.negative? || cb.arity >= 4
          element.attribute_changed_callback(name, old_value, new_value, namespace)
        else
          element.attribute_changed_callback(name, old_value, new_value)
        end
      rescue StandardError
        nil
      end

      # An open `details` joining an exclusive accordion group that already has an
      # open member closes itself — the member that was already there wins,
      # whichever order the parser or a script produced them in. A details the
      # parser opened also owes a toggle event, which it has had no attribute
      # change to queue.
      def run_details_insertion_steps(added_nodes)
        found = []
        added_nodes.each do |node|
          next unless node.respond_to?(:element?) && node.element?

          found << node if node.name == "details"
          # Only descend when there is something to descend into: appending a
          # leaf element (the shape of bulk DOM construction) then costs one
          # name comparison rather than a backend query.
          next unless node.respond_to?(:first_element_child) && node.first_element_child

          found.concat(node.css("details").to_a)
        end
        return if found.empty?

        # One batch across every added node: the whole insertion is a single
        # pass, so a group that arrives together settles on its first open
        # member rather than its last.
        HTMLDetailsElement.run_insertion_steps(found.filter_map { |backend| @document.wrap_node(backend) })
      rescue StandardError
        nil
      end

      # A select's list of options gained or lost members: run its selectedness
      # setting algorithm. Options (or optgroups holding them) landing in or
      # leaving a select — directly, or under one of its optgroups — affect that
      # select's list. A select arriving inside an inserted subtree has its own
      # list settled only if that never happened (the fragment parser built it):
      # inserting or moving the select changes nothing in its list. Only the
      # parent and grandparent are consulted, so an ordinary mutation elsewhere
      # costs two name checks.
      def run_select_mutation_steps(target_node, added_nodes, removed_nodes)
        owner = owning_select_node(target_node)
        if owner
          arrived = added_nodes.select { |node| option_list_member?(node) }
          if !arrived.empty? || removed_nodes.any? { |node| option_list_member?(node) }
            @document.wrap_node(owner)&.__internal_options_changed__(arrived)
          end
        end

        selects = []
        added_nodes.each do |node|
          next unless node.respond_to?(:element?) && node.element?

          selects << node if node.name == "select"
          next unless node.respond_to?(:first_element_child) && node.first_element_child

          selects.concat(node.css("select").to_a)
        end
        selects.each { |node| @document.wrap_node(node)&.__internal_settle_selectedness_once__ }
      rescue StandardError
        nil
      end

      # The select whose list of options a child-list mutation on `node` touches:
      # the select itself, or the select an optgroup sits in.
      def owning_select_node(node)
        return nil unless node.respond_to?(:name)
        return node if node.name == "select"
        return nil unless node.name == "optgroup"

        parent = node.respond_to?(:parent) ? node.parent : nil
        parent if parent.respond_to?(:name) && parent.name == "select"
      end

      def option_list_member?(node)
        node.respond_to?(:element?) && node.element? && %w[option optgroup].include?(node.name)
      end

      # Fire MutationObserver childList records
      def notify_child_list_mutation(
        target_node:,
        added_nodes:,
        removed_nodes:,
        previous_sibling: nil,
        next_sibling: nil
      )
        @document.__internal_note_tree_mutation__
        target = @document.wrap_node(target_node)
        return nil unless target
        return nil if added_nodes.empty? && removed_nodes.empty?

        # Custom Element connected/disconnected callbacks, script execution, and
        # blank-iframe load all require the subtree to be connected to the
        # document (the script/iframe paths already check is_connected?, and
        # connectedCallback fires only when connected). So skip the O(subtree)
        # walk for mutations within a still-detached tree — the common case
        # during bulk DOM construction, where nothing in the walk can fire.
        if !target.respond_to?(:is_connected?) || target.is_connected?
          added_nodes.each { |nk| notify_connected_subtree(nk) }
          removed_nodes.each { |nk| notify_disconnected_subtree(nk) }
        end

        # HTML's details insertion steps run wherever the element lands, not only
        # in a connected tree, so an accordion group assembled off-document is
        # already consistent by the time it is attached.
        run_details_insertion_steps(added_nodes)
        run_select_mutation_steps(target_node, added_nodes, removed_nodes)

        # MutationRecords are only needed when something is observing; skip the
        # eager wrapping + record entirely when no observer is registered.
        return nil unless @observer_manager.any?

        wrapped_added = added_nodes.map { |node| @document.wrap_node(node) }.compact
        wrapped_removed = removed_nodes.map { |node| @document.wrap_node(node) }.compact

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
        # `observe(t, {childList: false, attributes: true})`).
        #
        # The transient registered observers of remove step 20 are added by the
        # removal primitive (`Document#detach_node`), not here: that step is not
        # guarded by suppressObservers, so it must also run for the removals
        # that queue no record.
        @observer_manager.observers_matching(target).each do |observer|
          entry = observer.find_matching_entry(target)
          next unless entry

          observer.enqueue(record) if entry[:child_list]
        end

        nil
      end

      # Fire MutationObserver attribute records
      def notify_attribute_mutation(target_node:, attribute_name:, old_value:, namespace: nil)
        # A namespaced attribute keeps its local name as-is; a plain HTML
        # attribute is lower-cased.
        attr = namespace ? attribute_name.to_s : attribute_name.to_s.downcase
        @document.__internal_note_attribute_mutation__(attr, target_node)
        target = @document.wrap_node(target_node)
        return nil unless target
        new_value = target_node[attr]

        # Custom Element attributeChangedCallback (synchronous)
        notify_attribute_changed(target, attr, old_value, new_value, namespace)

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
        @document.__internal_note_character_data_mutation__(target_node, old_value)
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
