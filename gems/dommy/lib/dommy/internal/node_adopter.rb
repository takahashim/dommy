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
    #   - a `<template>`'s contents, which are not in its child list, and which
    #     the import copies in a shape of its own between an HTML and an XML
    #     document.
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
        # An Attr has no parent to be removed from, so it stays on its
        # element; only its node document changes.
        return node.__internal_adopt__(@document) if node.is_a?(Attr)
        src = node.__dommy_backend_node__ if node.is_a?(Node)
        return nil unless src

        # WHATWG adopt removes the node from its parent first — a full remove, so
        # the old parent gets its removing steps AND its childList record.
        # The removal is the old document's: its custom elements get their
        # disconnected reactions there.
        if src.parent
          source = node.respond_to?(:document) && node.document.respond_to?(:remove_node_with_notify) ? node.document : @document
          source.remove_node_with_notify(src)
        end

        # Same document: just return the wrapper after the detach above.
        return @document.wrap_node(src) if src.document == backend_doc
        return adopt_doctype(node, src) if node.is_a?(DocumentType)

        old_document = node.respond_to?(:document) ? node.document : nil
        adopted = adopt_across_documents(node, src)
        enqueue_adopted_callbacks(adopted.__dommy_backend_node__, old_document)
        adopted
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
          Transfer.new(source_document, @document).carry_over(node, adopted)
          enqueue_adopted_callbacks(adopted, source_document)
        end
        adopted
      end

      private

      def backend_doc = @document.backend_doc

      # DOM adopt step 3.3: each custom element among the adopted node's
      # shadow-including inclusive descendants gets an adoptedCallback
      # reaction, given the old and the new document.
      def enqueue_adopted_callbacks(root, old_document)
        return unless root && old_document && !old_document.equal?(@document)

        @document.__internal_each_shadow_including_element__(root) do |node|
          element = @document.__internal_peek_wrapper__(node)
          next unless element.respond_to?(:__internal_ce_custom__?) && element.__internal_ce_custom__?

          CEReactions.enqueue_callback(element, "adoptedCallback", [old_document, @document])
        end
      end

      # Cross-document DocumentType: Makiri can't import a doctype node between
      # arenas, so re-create it in the destination's backend from its name /
      # publicId / systemId (as createDocument does), then re-bind the caller's
      # wrapper onto the new node so JS identity survives the move.
      def adopt_doctype(node, src)
        adopted = Backend.create_document_type(node.name, node.public_id, node.system_id, backend_doc)
        Transfer.new(node.document, @document).reseat(node, src, adopted)
        node
      rescue StandardError => e
        # Returning the node unchanged would read as a successful adoption while
        # its ownerDocument never moved, so the caller hears about it instead.
        raise DOMException::NotSupportedError, "Cannot adopt this doctype: #{e.message}"
      end

      # Hand the detached source to the backend, which returns the node now
      # owned by the destination — an imported copy for Makiri. Then carry the
      # wrapper, the subtree's wrappers, and any template contents over.
      def adopt_across_documents(node, src)
        transfer = Transfer.new(node.respond_to?(:document) ? node.document : nil, @document)
        adopted = Backend.adopt(src, backend_doc)

        transfer.reseat(node, src, adopted)
        transfer.carry_over(src, adopted)
        node
      end

      # One adopt between two documents: the walk that carries everything bound
      # to an original subtree onto the backend's copy of it. Both documents
      # stay the same for the whole walk, so they are its state rather than an
      # argument of every step.
      class Transfer
        def initialize(source, destination)
          @source = source
          @destination = destination
        end

        # A deep adopt imports a fresh copy of the whole subtree, so each live
        # wrapper in it must be re-bound onto its copy — otherwise it stays
        # bound to the old document. Import preserves document order, so the
        # two subtrees are walked together.
        def carry_over(orig, copy)
          reseat_wrapper(orig, copy)
          if destination_registry.template_node?(orig)
            carry_over_template(orig, copy)
          else
            carry_over_each(orig.children.to_a, copy.children.to_a)
          end
        end

        # Move a wrapper the caller already holds — #adopt's own argument —
        # from `orig` in the source onto `copy` in the destination: drop the
        # source document's entry for it, let the wrapper re-bind itself, and
        # record it in the destination under the node it now wraps.
        def reseat(wrapper, orig, copy)
          @source.__internal_reset_wrapper__(orig) if @source.respond_to?(:__internal_reset_wrapper__)
          wrapper.__internal_reseat__(copy, @destination)
          @destination.__internal_register_wrapper__(copy, wrapper)
          wrapper
        end

        private

        # A length mismatch means the copies are not the import of the
        # originals, so nothing is paired at all rather than paired wrongly.
        def carry_over_each(origs, copies)
          return unless origs.length == copies.length

          origs.zip(copies).each { |orig, copy| carry_over(orig, copy) }
        end

        # HTML: adopting a `<template>` adopts its template contents
        # DocumentFragment along with it — the SAME fragment object, so
        # `template.content` keeps both its identity and its children across
        # the move. An HTML document's contents are the backend's own, which
        # its import copies as contents into an HTML document and as the
        # leading children into an XML one (which has no contents); an XML
        # document's live apart from the tree and move here one by one.
        # Whatever the import made of them, they end up as the destination
        # keeps contents, and the template's own children as its children.
        # Spec: https://html.spec.whatwg.org/#the-template-element (adopting steps)
        def carry_over_template(orig, copy)
          source_registry = @source.__internal_template_registry__
          src_frag = source_registry.existing_contents(orig)
          contents = src_frag ? src_frag.children.to_a : []
          children = orig.children.to_a
          dst_frag = destination_registry.contents(copy)
          from_html = !Backend.template_contents(orig).nil?
          to_html = !Backend.template_contents(copy).nil?

          if from_html && to_html
            carry_over_each(contents, dst_frag.children.to_a)
            carry_over_each(children, copy.children.to_a)
          elsif from_html
            copied = copy.children.to_a
            copied.first(contents.length).each { |node| move_node(node, dst_frag) }
            carry_over_each(contents, copied.first(contents.length))
            carry_over_each(children, copied.drop(contents.length))
          else
            if to_html
              # The import made the XML template's own children the contents.
              copied = dst_frag.children.to_a
              copied.each { |node| move_node(node, copy) }
            end
            carry_over_each(children, copy.children.to_a)
            adopt_detached_contents(contents, dst_frag)
            source_registry.release(orig)
          end
          reseat_wrapper(src_frag, dst_frag) if src_frag
        end

        # An XML document's contents, which no import reached, moved one by
        # one.
        def adopt_detached_contents(nodes, dst_frag)
          nodes.each do |node|
            moved = Backend.adopt(node, @destination.backend_doc)
            carry_over(node, moved)
            dst_frag.add_child(moved)
          end
        end

        # Put a copy the import placed where the destination does not keep it
        # into place. Not a DOM mutation — the node is where the adopt means it
        # to be — so a raw unlink.
        def move_node(node, parent)
          node.unlink
          parent.add_child(node)
        end

        def destination_registry = @destination.__internal_template_registry__

        # Look up the live wrapper for `orig` in the source document, if it
        # has one, and move it onto `copy`.
        def reseat_wrapper(orig, copy)
          return if orig.equal?(copy)
          return unless @source.respond_to?(:__internal_peek_wrapper__)

          wrapper = @source.__internal_peek_wrapper__(orig)
          return unless wrapper

          reseat(wrapper, orig, copy)
        end
      end
      private_constant :Transfer
    end
  end
end
