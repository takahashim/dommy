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
        element.__internal_run_pragma__ if element.respond_to?(:__internal_run_pragma__)
        autofocus_inserted(element)
      end

      # An element with an autofocus attribute inserted into a document
      # becomes an autofocus candidate (HTML §6.6.6).
      def autofocus_inserted(element)
        return unless element.respond_to?(:autofocus) && element.__internal_has_attribute__?("autofocus")

        @document.__internal_autofocus_inserted__(element)
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

      # The script children changed steps: a connected script whose children
      # changed gets its post-connection steps again — an empty script given
      # text runs then.
      def script_children_changed(element)
        return unless element.respond_to?(:__internal_prepare_script__)
        return unless element.is_connected?

        script_post_connection(element)
      end

      # The script attribute change steps: setting `src` on a connected script
      # runs its post-connection steps (removing it does not).
      def script_attribute_changed(element, name, value, namespace)
        return unless element.respond_to?(:__internal_prepare_script__)
        return unless namespace.nil? && name == "src" && !value.nil? && element.is_connected?

        script_post_connection(element)
      end

      private

      # The script HTML element post-connection steps, for a `<script>` that is
      # now genuinely connected (this walk also fires for additions to a
      # still-detached subtree).
      def run_connected_script(element)
        return unless element.respond_to?(:__internal_prepare_script__) # a <script>
        return unless element.respond_to?(:is_connected?) && element.is_connected?

        script_post_connection(element)
      end

      # HTML "prepare the script element" for a script that is not
      # parser-inserted, then the part of the processing model that applies to
      # it: an inline classic script executes right away, an external one when
      # its fetch completes (through external_script_runner, wired by the
      # integration layer, which owns the network — webpack/Vite load
      # on-demand chunks by injecting `<script src>` this way), and a module
      # script — inline or external — in a task of its own, never during the
      # insertion. Scripting is enabled only while a JS engine is attached
      # (script_runner); without one nothing is prepared, so a script inserted
      # before the engine arrives still runs at boot.
      def script_post_connection(element)
        return if element.__internal_parser_inserted__
        return unless @document.script_runner

        prepared = element.__internal_prepare_script__
        return unless prepared

        case prepared.type
        when :classic
          prepared.external ? run_external_connected_script(element, prepared.url) : run_inline_classic(element, prepared.source)
        when :module
          run_module_script(element, prepared)
        end
      end

      # A script-inserted INLINE classic script runs synchronously on
      # insertion, as "execute the script element": currentScript is the
      # element for the run (and for the report of its exception), then goes
      # back to whatever it was.
      def run_inline_classic(element, source)
        @document.__internal_with_current_script__(element) do
          @document.script_runner.call(source)
        rescue StandardError => e
          @report.call(e)
        end
      end

      # A module script is always "as soon as possible" here (not
      # parser-inserted): it runs in a task once its graph is ready, so even an
      # inline module with no imports never runs inside the insertion. The
      # integration layer's runner knows the element is a module from its
      # prepared state.
      def run_module_script(element, prepared)
        runner = @document.external_script_runner
        return unless runner

        queue_task do
          next unless element.owner_document.equal?(@document)

          runner.call(element, prepared.url)
        rescue StandardError => e
          @report.call(e)
        end
      end

      def queue_task(&block)
        scheduler = @document.__internal_scheduler__ if @document.respond_to?(:__internal_scheduler__)
        scheduler ? scheduler.set_timeout(block, 0) : block.call
      end

      # A script-inserted EXTERNAL `<script src>` loads and runs ASYNCHRONOUSLY
      # (per HTML spec), unlike an inline one: in a task of its own once its
      # fetch completes, never inside the insertion steps — which would execute
      # it mid-render and make the engine drain its microtask queue while JS is
      # still on the stack (re-entering an unrelated microtask such as Vue's
      # `nextTick` flush on a half-built component tree, as note.com's
      # RecommendTemplate once did). Not a microtask either: microtasks the
      # inserting script queued run while it is still `document.currentScript`,
      # and this script must not. "Execute the script element" checks only
      # that the element is still in the document it was prepared in, so a
      # script removed after insertion still runs.
      #
      # One written by document.write is the parser's pending parsing-blocking
      # script instead: it runs once the writing script returns, before the
      # parser moves on — the next microtask checkpoint, here.
      def run_external_connected_script(element, src)
        runner = @document.external_script_runner
        return unless runner

        schedule = @document.__internal_document_writing__ ? method(:defer) : method(:queue_task)
        schedule.call do
          next unless element.owner_document.equal?(@document)

          runner.call(element, src)
        rescue StandardError => e
          @report.call(e)
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
        # The content attribute: `src=""` names no resource, where the IDL `src`
        # resolves it to the document's own address (a URL reflection).
        return unless BLANK_IFRAME_SRCS.include?(element.__internal_attribute_value__("src").to_s.strip)

        ensure_blank_content_document(element)
        defer do
          element.__internal_fire_event__("load")
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
          next unless node.element?

          found << node if node.name == name
          next unless node.first_element_child

          found.concat(node.css(name).to_a)
        end
      end

      # The select whose list of options a child-list mutation on `node` touches:
      # the select itself, or the select an optgroup sits in.
      def owning_select_node(node)
        return nil unless node
        return node if node.name == "select"
        return nil unless node.name == "optgroup"

        parent = node.parent
        parent if parent&.name == "select"
      end

      # An <option> or <optgroup> that joins or leaves a select's list of
      # options. HTML's: an SVG element of the same name is not one, and the
      # only way to ask is the wrapper (which the document has cached, so this
      # costs a lookup rather than a second wrap in `arrived_options`).
      def option_list_member?(node)
        return false unless node.element?
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
