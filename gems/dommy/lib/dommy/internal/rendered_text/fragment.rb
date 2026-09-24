# frozen_string_literal: true

module Dommy
  module Internal
    module RenderedText
      # The `innerText` / `outerText` setters, both built on HTML's "rendered
      # text fragment": the value split on line breaks, a Text node for each
      # run of text between them and a <br> for each break (CRLF counts once).
      module Fragment
        module_function

        # The innerText setter: "set the inner text steps".
        def set_inner(element, value)
          element.__internal_replace_all__(fragment(element.document, value.to_s).map(&:__dommy_backend_node__))
          nil
        end

        # The outerText setter: the element is replaced by the fragment (an
        # empty Text node when there is none), and the Text nodes it lands
        # between merge with it.
        def set_outer(element, value)
          raise DOMException::NoModificationAllowedError, "outerText requires a parent" if element.parent_node.nil?

          following = element.next_sibling
          preceding = element.previous_sibling
          nodes = fragment(element.document, value.to_s)
          nodes = [element.document.create_text_node("")] if nodes.empty?
          element.replace_with(*nodes)
          merge_next_text_node(following)
          merge_next_text_node(preceding) if preceding.is_a?(TextNode)
          nil
        end

        def fragment(document, value)
          value.scan(/[^\r\n]+|\r\n|\r|\n/).map do |piece|
            piece.start_with?("\r", "\n") ? document.create_element("br") : document.create_text_node(piece)
          end
        end

        def merge_next_text_node(node)
          return unless node.is_a?(TextNode)

          following = node.next_sibling
          return unless following.is_a?(TextNode)

          node.data = node.data + following.data
          following.remove
        end

        # The two setters are the module; the rest is how.
        private_class_method :fragment, :merge_next_text_node
      end
    end
  end
end
