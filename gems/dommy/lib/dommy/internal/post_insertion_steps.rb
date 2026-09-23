# frozen_string_literal: true

module Dommy
  module Internal
    # What HTML says happens to an element because it was inserted, beyond the
    # DOM's own insertion: a connected `<script>` runs, a blank `<iframe>` gets
    # a document and fires `load`, a `<details>` group settles on one open
    # member, a `<select>` re-runs its selectedness algorithm.
    #
    # These are element behaviours, not mutation notification, which is why they
    # are not MutationCoordinator's — it calls in here and stays about observers
    # and custom element reactions.
    #
    # `report` takes an exception the page should hear about (a script it owns
    # threw); the algorithms below have no rescue of their own, because a
    # failure in one of them is a bug here rather than something the page did.
    class PostInsertionSteps
      # A srcless ("blank"/about:blank) iframe is the one we give a document to;
      # a `src` iframe is left to the integration layer.
      BLANK_IFRAME_SRCS = ["", "about:blank"].freeze

      def initialize(document, report)
        @document = document
        @report = report
      end

      # The per-element steps of a connected insertion.
      def connected(element)
        run_connected_script(element)
        fire_blank_iframe_load(element)
      end

      # A `<details>` among the inserted nodes: exactly one member of a group
      # may be open, and the member that was already there wins, whichever order
      # the parser or a script produced them in. A details the parser opened
      # also owes a toggle event, which it has had no attribute change to queue.
      def details_inserted(added_nodes)
        found = collect_elements(added_nodes, "details").filter_map { |backend| wrap_html(backend) }
        return if found.empty?

        # One batch across every added node: the whole insertion is a single
        # pass, so a group that arrives together settles on its first open
        # member rather than its last.
        HTMLDetailsElement.run_insertion_steps(found)
      end

      # A select's list of options gained or lost members: run its selectedness
      # setting algorithm. Options (or optgroups holding them) landing in or
      # leaving a select — directly, or under one of its optgroups — affect that
      # select's list. A select arriving inside an inserted subtree has its own
      # list settled only if that never happened (the fragment parser built it):
      # inserting or moving the select changes nothing in its list. Only the
      # parent and grandparent are consulted, so an ordinary mutation elsewhere
      # costs two name checks.
      def select_mutated(target_node, added_nodes, removed_nodes)
        if (owner = owning_select_node(target_node))
          arrived = added_nodes.select { |node| option_list_member?(node) }
          if !arrived.empty? || removed_nodes.any? { |node| option_list_member?(node) }
            wrap_html(owner)&.__internal_options_changed__(arrived_options(arrived))
          end
        end

        collect_elements(added_nodes, "select").each do |node|
          wrap_html(node)&.__internal_settle_selectedness_once__
        end
      end

      private

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
          begin
            runner.call(source)
          rescue StandardError => e
            @report.call(e)
          end
        elsif @document.external_script_runner &&
              element.respond_to?(:__internal_take_pending_src__) &&
              (src = element.__internal_take_pending_src__)
          run_external_connected_script(element, src)
        end
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
        defer do
          next unless element.respond_to?(:is_connected?) && element.is_connected?

          begin
            @document.external_script_runner.call(element, src)
          rescue StandardError => e
            @report.call(e)
          end
        end
      end

      # A blank `<iframe>` connected to the document gets an empty nested
      # browsing context (a real, complete content document) and fires its
      # `load` event ASYNCHRONOUSLY (a microtask), like a real browser —
      # handlers are commonly attached after insertion (`appendChild(f);
      # f.onload = …`). Without this, code that awaits a blank iframe's load and
      # then reads `iframe.contentWindow.document` hangs: FingerprintJS's
      # `withIframe` (its font sources) does exactly that, which hung note.com's
      # tracking plugin and its whole Nuxt hydration.
      def fire_blank_iframe_load(element)
        return unless element.respond_to?(:local_name) && element.local_name == "iframe"
        return unless element.respond_to?(:is_connected?) && element.is_connected?
        return unless element.respond_to?(:src) && BLANK_IFRAME_SRCS.include?(element.src.to_s.strip)

        ensure_blank_content_document(element)
        defer do
          element.dispatch_event(Event.new("load"))
        rescue StandardError => e
          @report.call(e)
        end
      end

      # Give a blank iframe a fresh empty document (or its `srcdoc`) so
      # `contentWindow` / `contentDocument` resolve and DOM ops + measurement
      # inside it work (readyState defaults to "complete"). No-op if it already
      # has one.
      def ensure_blank_content_document(element)
        return unless element.respond_to?(:__internal_build_blank_content_document__)
        return if element.respond_to?(:content_document) && element.content_document

        # The frame builds it, not this: the document URL a blank browsing
        # context gets (about:blank, about:srcdoc) and the base URL it inherits
        # from its creator are the frame's business, and a second copy here
        # built a Window at the library's default `http://localhost/`.
        element.__internal_set_content_document__(element.__internal_build_blank_content_document__)
      end

      # Run at the next microtask checkpoint, or inline when the document has no
      # scheduler to defer onto.
      def defer(&block)
        scheduler = (@document.default_view&.scheduler if @document.respond_to?(:default_view))
        scheduler ? scheduler.queue_microtask(block) : block.call
      end

      # The elements named `name` among the added nodes and their subtrees.
      # Descends only when there is something to descend into: appending a leaf
      # element (the shape of bulk DOM construction) then costs one name
      # comparison rather than a backend query.
      def collect_elements(added_nodes, name)
        added_nodes.each_with_object([]) do |node, found|
          next unless node.respond_to?(:element?) && node.element?

          found << node if node.name == name
          next unless node.respond_to?(:first_element_child) && node.first_element_child

          found.concat(node.css(name).to_a)
        end
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

      # An <option> or <optgroup> that joins or leaves a select's list of
      # options. HTML's: an SVG element of the same name is not one, and the
      # only way to ask is the wrapper (which the document has cached, so this
      # costs a lookup rather than a second wrap in `arrived_options`).
      def option_list_member?(node)
        return false unless node.respond_to?(:element?) && node.element?
        return false unless %w[option optgroup].include?(node.name)

        !wrap_html(node).nil?
      end

      # The wrapper for a backend node, when HTML's steps are the ones that
      # apply to it — every query here matches on local name alone, and an SVG
      # `<details>` answers to that name. The document owns the rule (and the
      # explanation of why there is one).
      def wrap_html(node) = @document.__internal_html_element_wrapper__(node)

      # The options an insertion brought into a select's list, wrapped, in tree
      # order: an arriving option is itself, an arriving optgroup contributes
      # the options it carries.
      def arrived_options(arrived)
        arrived.flat_map { |node|
          node.name == "option" ? [node] : node.css("option").to_a
        }.filter_map { |node| wrap_html(node) }
      end
    end
  end
end
