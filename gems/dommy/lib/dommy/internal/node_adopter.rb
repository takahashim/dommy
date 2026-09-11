# frozen_string_literal: true

module Dommy
  module Internal
    # WHATWG "adopt": move a node into a destination document.
    #
    # In a browser this is a pointer swap — the node keeps its identity and its
    # node document changes. Dommy's backends cannot all do that: Makiri keeps
    # each document's nodes in its own arena, so "moving" one means importing a
    # copy into the destination and abandoning the original. Everything bound to
    # the original then has to be carried over to the copy, and that is what
    # this class is: the destination document's answer to "what else moves".
    #
    #   - the caller's wrapper, so `destination.adoptNode(x)` is still `x`;
    #   - every live wrapper in the subtree, so a reference page script is
    #     holding (an aria element reference, a queued MutationRecord's target)
    #     keeps pointing at a node in the right document;
    #   - a `<template>`'s contents, which are not in its child list and so are
    #     reachable only through the source document's registry.
    #
    # Spec: https://dom.spec.whatwg.org/#concept-node-adopt
    class NodeAdopter
      # `document` is the DESTINATION — the document the nodes are moving into.
      def initialize(document)
        @document = document
      end

      # The DOM `adoptNode(node)` operation. Returns the node's wrapper, re-bound
      # to the adopted node when the backend could not move it in place.
      def adopt(node)
        # WHATWG adopt: a Document can't be adopted into another document.
        if node.is_a?(Dommy::Document)
          raise DOMException::NotSupportedError, "A Document node cannot be adopted."
        end
        return nil unless node.respond_to?(:__dommy_backend_node__)

        src = node.__dommy_backend_node__
        # WHATWG adopt removes the node from its parent first — a full remove, so
        # the old parent gets its removing steps AND its childList record.
        @document.remove_node_with_notify(src) if src.parent

        # Same document: just return the wrapper after the detach above.
        return @document.wrap_node(src) if src.document == backend_doc
        return adopt_doctype(node, src) if node.is_a?(DocumentType)

        adopt_across_documents(node, src)
      end

      # Adopt a raw backend node that has no wrapper of its own to re-bind — a
      # DocumentFragment's children on a cross-document insert. Beyond the
      # backend move it does what #adopt does for the node it is handed: re-bind
      # any live wrapper onto the adopted node, and carry a `<template>`'s
      # contents across.
      def adopt_backend_node(node, source_document)
        return node if node.document == backend_doc

        adopted = Backend.adopt(node, backend_doc)
        if source_document && !source_document.equal?(@document)
          reseat_wrapper(node, adopted, source_document)
          reseat_descendant_wrappers(node, adopted, source_document)
          adopt_template_contents(node, adopted, source_document)
        end
        adopted
      end

      # Move each live wrapper for a descendant of `src_root` onto the matching
      # node in `dst_root` (the imported copy), pruning it from the source
      # document. `include_root` also re-binds the root pair — #adopt re-binds
      # its own root wrapper by hand, but a template's content fragment has no
      # such caller.
      def reseat_descendant_wrappers(src_root, dst_root, src_doc, include_root: false)
        return unless src_doc.respond_to?(:__internal_peek_wrapper__)

        each_node_pair(src_root, dst_root) do |orig, copy|
          next if orig.equal?(src_root) && !include_root

          reseat_wrapper(orig, copy, src_doc)
        end
      end

      # HTML: adopting a `<template>` adopts its template contents
      # DocumentFragment along with it — the SAME fragment object, so
      # `template.content` keeps both its identity and its children across the
      # move. The contents are not in the template's child list, so neither the
      # backend's adopt nor the descendant walk above ever reaches them; without
      # this the adopted template comes out empty. Recurses, since a template's
      # contents can hold further templates.
      # Spec: https://html.spec.whatwg.org/#the-template-element (adopting steps)
      def adopt_template_contents(src_root, dst_root, src_doc)
        return if src_doc.nil? || src_doc.equal?(@document)
        return unless src_doc.respond_to?(:__internal_template_registry__)

        src_registry = src_doc.__internal_template_registry__
        each_node_pair(src_root, dst_root) do |orig, copy|
          src_frag = src_registry.raw_fragment_for(orig)
          next unless src_frag

          adopt_one_template_content(src_frag, copy, src_doc)
        end
      end

      private

      def backend_doc = @document.backend_doc

      # Cross-document DocumentType: Makiri can't import a doctype node between
      # arenas, so re-create it in the destination's backend from its name /
      # publicId / systemId (as createDocument does), then re-bind the caller's
      # wrapper onto the new node so JS identity survives the move.
      def adopt_doctype(node, src)
        adopted = begin
          Backend.create_document_type(node.name, node.public_id, node.system_id, backend_doc)
        rescue StandardError
          nil
        end
        return node unless adopted

        reseat_known_wrapper(node, src, adopted, node.document)
        node
      end

      # Hand the detached source to the backend, which returns the node now
      # owned by the destination — an imported copy for Makiri. Then carry the
      # wrapper, the subtree's wrappers, and any template contents over.
      def adopt_across_documents(node, src)
        src_doc = node.respond_to?(:document) ? node.document : nil
        adopted = Backend.adopt(src, backend_doc)

        reseat_known_wrapper(node, src, adopted, src_doc)
        # A deep adopt imports a fresh copy of the whole subtree, so any live
        # descendant wrapper must be re-bound onto its corresponding copy —
        # otherwise it stays bound to the old document. Import preserves document
        # order, so walk both subtrees in lockstep.
        reseat_descendant_wrappers(src, adopted, src_doc)
        adopt_template_contents(src, adopted, src_doc)
        node
      end

      def adopt_one_template_content(src_frag, template_copy, src_doc)
        frag = Parser.fragment("", owner_doc: backend_doc)
        # Snapshot before moving: the backend either relocates each node in place
        # (Nokogiri) or hands back an imported copy (Makiri, which cannot move a
        # node between arenas), and the pairs drive the wrapper re-bind either way.
        src_frag.children.to_a.each do |child|
          moved = Backend.adopt(child, backend_doc)
          adopt_template_contents(child, moved, src_doc)
          reseat_wrapper(child, moved, src_doc)
          reseat_descendant_wrappers(child, moved, src_doc)
          frag.add_child(moved)
        end
        @document.__internal_template_registry__.store(template_copy, frag)
        reseat_wrapper(src_frag, frag, src_doc)
      end

      # Each (original, copy) pair of the two subtrees, in document order. A
      # length mismatch means the copy is not the import of the original, so
      # nothing is paired at all rather than paired wrongly.
      def each_node_pair(src_root, dst_root)
        src_nodes = NodeTraversal.subtree_nodes(src_root)
        dst_nodes = NodeTraversal.subtree_nodes(dst_root)
        return if src_nodes.length != dst_nodes.length

        src_nodes.zip(dst_nodes).each { |pair| yield(*pair) }
      end

      # Look up the live wrapper for `orig` in the source document, if it has
      # one, and move it onto `copy`.
      def reseat_wrapper(orig, copy, src_doc)
        return if orig.equal?(copy)
        return unless src_doc.respond_to?(:__internal_peek_wrapper__)

        wrapper = src_doc.__internal_peek_wrapper__(orig)
        return unless wrapper

        reseat_known_wrapper(wrapper, orig, copy, src_doc)
      end

      # Move a wrapper the caller already holds — #adopt's own argument — from
      # `orig` in `src_doc` onto `copy` here: drop the source document's entry
      # for it, let the wrapper re-bind itself, and record it in the destination
      # under the node it now wraps.
      def reseat_known_wrapper(wrapper, orig, copy, src_doc)
        src_doc.__internal_reset_wrapper__(orig) if src_doc.respond_to?(:__internal_reset_wrapper__)
        wrapper.__internal_reseat__(copy, @document)
        @document.__internal_register_wrapper__(copy, wrapper)
        wrapper
      end
    end
  end
end
