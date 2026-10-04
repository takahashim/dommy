# frozen_string_literal: true

module Dommy
  module Internal
    # Manages <template> element contents, the DocumentFragment exposed as the
    # element's `content` property (per HTML spec).
    #
    # In an HTML document the contents are the backend's own: Lexbor keeps a
    # template's contents in a content fragment of its own, off the child list,
    # so they are invisible to querySelector, getElementById, etc. on the main
    # tree, and the backend's HTML serialization of any ancestor writes them.
    # An XML document's backend tree has no contents, so each template's is a
    # detached fragment this registry holds.
    class TemplateContentRegistry
      def initialize(document)
        @document = document
        # Backend.identity_key(template_node) → detached backend fragment (an
        # XML document's contents only)
        @fragments = {}
        # Backend.identity_key(template_node) of the HTML templates whose
        # parsed contents have had their scripts marked
        @marked = {}
      end

      # Replace the template's content with `html`.
      #
      # HTML's innerHTML setter retargets a `<template>` to its template
      # contents DocumentFragment and does "replace all with fragment" THERE, so
      # the content object itself is NOT exchanged: `template.content` is the
      # same object before and after, an existing reference to it stays live,
      # and a MutationObserver watching it sees the swap. Only the fragment's
      # children change.
      #
      # Spec: https://html.spec.whatwg.org/#dom-innerhtml
      def attach(template_element, html)
        content = fragment_for(template_element)
        parsed = Parser.fragment(html.to_s, owner_doc: @document.backend_doc)
        nodes = parsed.children.to_a
        content.__internal_replace_all__(nodes)
        mark_parser_inserted_scripts(nodes)
        content
      end

      # The wrapped contents of a template element.
      def fragment_for(template_element)
        @document.wrap_node(contents(template_element.__dommy_backend_node__))
      end

      # The backend fragment holding `template_node`'s contents — its own
      # content fragment in an HTML document, a detached one (made empty on
      # first use) in an XML document. The same fragment every time.
      def contents(template_node)
        Backend.template_contents(template_node) ||
          (@fragments[Backend.identity_key(template_node)] ||= empty_fragment)
      end

      # The fragment holding `template_node`'s contents, or nil for an XML
      # document's template that has none yet (not made on the way).
      def existing_contents(template_node)
        Backend.template_contents(template_node) || @fragments[Backend.identity_key(template_node)]
      end

      def content_nodes(template_node)
        fragment = existing_contents(template_node)
        fragment ? fragment.children.to_a : []
      end

      # Whether the contents live apart from the backend node — an XML
      # document's — so that copying the node does not copy them.
      def detached?(template_node)
        @fragments.key?(Backend.identity_key(template_node))
      end

      # Drop an adopted-away template's detached contents.
      def release(template_node)
        @fragments.delete(Backend.identity_key(template_node))
      end

      def inner_html_of(template_element)
        content_nodes(template_element.__dommy_backend_node__).map(&:to_html).join
      end

      # A template element in the HTML namespace — the only kind with contents.
      def template_node?(node)
        node.element? && node.local_name == "template" &&
          Backend.namespace_uri(node) == Namespaces::HTML
      end

      # After the HTML parser produced `root` (a page parse, innerHTML), clear
      # "force async" on the scripts it put in template contents. The contents
      # are already where they belong.
      #
      # Uses a C-accelerated `css` query for descendants (rather than a
      # Ruby-level full traverse) so this runs on every page parse cheaply — a
      # no-op fast path when the document has no <template>.
      def migrate_descendants(root)
        targets = []
        targets << root if template_node?(root)
        targets.concat(root.css("template").to_a)
        targets.each { |t| mark_contents(t) }
      end

      # The XML parser appends an HTML <template>'s children to its template
      # contents rather than to the element (HTML's "Parsing XML documents"),
      # but the backend's XML tree has no contents and keeps them as children.
      # Move each parsed template's children into its detached contents. Only
      # for freshly parsed nodes: a <template> script builds in an XML document
      # keeps the children it is given.
      #
      # This normalizes Dommy's internal representation to the spec model
      # rather than performing a DOM mutation — the nodes are the template's
      # contents before and after — so it deliberately uses a raw unlink.
      #
      # Spec: https://html.spec.whatwg.org/multipage/xhtml.html#parsing-xhtml-documents
      def migrate_xml_descendants(root)
        NodeTraversal.subtree_nodes(root).each do |node|
          next unless template_node?(node) && !detached?(node)

          fragment = contents(node)
          node.children.to_a.each do |child|
            child.unlink
            fragment.add_child(child)
          end
          mark_parser_inserted_scripts(fragment.children.to_a)
        end
      end

      private

      def empty_fragment
        Parser.fragment("", owner_doc: @document.backend_doc)
      end

      # Once per template: the parser's scripts in its contents, and in the
      # contents of the templates nested there (which a `css` query on the
      # main tree does not reach).
      def mark_contents(template_node)
        key = Backend.identity_key(template_node)
        return if @marked.key?(key)

        @marked[key] = true
        mark_parser_inserted_scripts(content_nodes(template_node))
      end

      # After parser-produced nodes land in a template's contents, clear "force
      # async" (HTML §4.12.1.1) on every script among them (descendants and
      # nested contents included) — `attach` (innerHTML=) and the parse paths
      # bypass Document#__internal_run_parsed_insertion_steps__ and
      # Element#mark_fragment_scripts_started, so nothing else does this for a
      # content fragment's scripts. NOT "already started": template content has
      # no owner document to execute a script in, so that flag guards against
      # nothing here — only force async, which `.async` can still observe.
      def mark_parser_inserted_scripts(nodes)
        nodes.each do |node|
          next unless node.element?

          if node.name == "script"
            wrapped = @document.wrap_node(node)
            wrapped.__internal_mark_parser_inserted__ if wrapped.respond_to?(:__internal_mark_parser_inserted__)
          end
          mark_contents(node) if template_node?(node)
          mark_parser_inserted_scripts(node.children.to_a)
        end
      end
    end
  end
end
