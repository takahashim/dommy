# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's "set and filter HTML" for setHTMLUnsafe() (Element, ShadowRoot)
    # and the static Document.parseHTMLUnsafe(): the HTML fragment parsing
    # algorithm with allowDeclarativeShadowRoots true, and the parser
    # scripting mode Inert — or Fragment with `runScripts: true`.
    #
    # No Sanitizer: the `sanitizer` option is accepted and ignored (its
    # default for these methods, an empty configuration, removes nothing;
    # Dommy has no Sanitizer interface to pass anything else).
    #
    # Spec: https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#set-and-filter-html
    module UnsafeHtml
      module_function

      # SetHTMLUnsafeOptions' runScripts (false by default).
      def run_scripts?(options)
        return false if options.nil? || options.equal?(Bridge::UNDEFINED)
        raise Bridge::TypeError, "setHTMLUnsafe options must be a dictionary" unless options.is_a?(Hash)

        WebIDL.boolean(options.key?("runScripts") ? options["runScripts"] : options[:runScripts])
      end

      # "Set and filter HTML" given `target` (an Element, a template's
      # contents, or a ShadowRoot), `context` (the element the markup is
      # parsed in: `target` itself, the template, or the shadow root's host)
      # and the markup: parse, then "replace all" with the result in target.
      def set(document, target, context, html, run_scripts:)
        nodes = parse_fragment(document, context, html.to_s, run_scripts: run_scripts,
                                                             registry: CustomElementRegistry.for_node(target))
        target.__internal_replace_all__(nodes)
        nil
      end

      # The HTML fragment parsing algorithm with declarative shadow roots
      # allowed: the parsed backend nodes, not yet in any tree, their
      # declarative shadow roots attached and their scripts flagged for the
      # scripting mode.
      def parse_fragment(document, context, html, run_scripts:, registry:)
        context_bn = context.__dommy_backend_node__
        fragment = html_fragment(document, context_bn, html)
        roots = DeclarativeShadowRoots.attach(document, fragment)
        nodes = fragment.children.to_a
        # The fragment parser creates its elements without the synchronous
        # custom elements flag: a defined one is upgraded by a reaction, with
        # the registry of the tree it is parsed into.
        document.__internal_enqueue_created_upgrades__(nodes, registry)
        roots.each do |root|
          root_registry = root.__internal_custom_element_registry__
          document.__internal_enqueue_created_upgrades__(root.__dommy_backend_node__.children.to_a, root_registry) if root_registry
        end
        flag_scripts(document, fragment, run_scripts)
        nodes
      end

      # The HTML parser even in an XML document (setHTMLUnsafe always parses
      # HTML): an XML-backed document's markup is parsed in an HTML scratch
      # document and the nodes brought over.
      def html_fragment(document, context_bn, html)
        doc_bn = document.backend_doc
        return Parser.fragment(html, owner_doc: doc_bn, context: context_bn) if Backend.html_backed?(doc_bn)

        scratch = Backend.parse("")
        scratch_context = Backend.create_element(context_bn.local_name, Backend.namespace_uri(context_bn), scratch)
        parsed = Parser.fragment(html, owner_doc: scratch, context: scratch_context)
        fragment = Parser.fragment("", owner_doc: doc_bn)
        parsed.children.to_a.each { |node| fragment.add_child(Backend.adopt(node, doc_bn)) }
        fragment
      end

      # Inert: every script the parser made (in the declarative shadow trees
      # too) is "already started", so it never runs. Fragment: the parser
      # does not give them a parser document, so they run once inserted.
      # Either way the parser clears "force async".
      def flag_scripts(document, fragment, run_scripts)
        document.__internal_each_shadow_including_element__(fragment) do |node|
          next unless node.local_name == "script"

          script = document.wrap_node(node)
          next unless script.respond_to?(:__internal_mark_parser_inserted__)

          script.__internal_mark_parser_inserted__
          script.__internal_mark_script_already_started__ unless run_scripts
        end
      end

      # Document.parseHTMLUnsafe(html): a new HTML document with the creator's
      # origin and the URL about:blank, allowing declarative shadow roots,
      # parsed from the markup. It has no browsing context, so its scripts
      # never run.
      def parse_document(html, window)
        document = Document.new(nil, backend_doc: Backend.parse(html.to_s))
        document.__internal_allow_declarative_shadow_roots__ = true
        document.__internal_attach_declarative_shadow_roots__(document.backend_doc)
        document.task_scheduler = window.scheduler if window.respond_to?(:scheduler)
        document.__internal_parsed_roots__.each { |root| document.migrate_template_descendants(root) }
        document.__internal_run_parsed_insertion_steps__
        document.__internal_parsed_roots__.each { |root| document.__internal_mark_scripts_already_started__(root) }
        creator = window.respond_to?(:document) ? window.document : nil
        document.__internal_set_creator__(creator, url: nil)
        document
      end
    end
  end
end
