# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # Whether an element is rendered at all — the question CSSOM's
      # getComputedStyle asks before it computes anything, since a non-rendered
      # element has an empty computed style (browsers answer "" for every
      # property).
      #
      # It is about tree position rather than about the cascade: disconnected,
      # outside the flat tree, or inside a frame that is not itself rendered.
      # Only the last of those needs a computed style, which arrives as the
      # `style_for` callable so this module does not reach back into Cascade.
      module Renderability
        # How far up the frame chain to walk before calling it a cycle.
        MAX_FRAME_DEPTH = 64

        module_function

        def not_rendered?(element, style_for)
          return true if element.respond_to?(:is_connected?) && !element.is_connected?
          return true if outside_flat_tree?(element)

          in_non_rendered_frame?(element, style_for)
        end

        # Walk flat-tree parents: a light child of a shadow host is in the flat
        # tree only if assigned to a slot, so an unslotted one (and its subtree)
        # is outside it.
        def outside_flat_tree?(element)
          node = element
          while node.respond_to?(:parent_element) && (host = node.parent_element)
            if host.respond_to?(:shadow_root) && host.shadow_root &&
               node.respond_to?(:assigned_slot) && node.assigned_slot.nil?
              return true
            end

            node = host
          end
          false
        end

        # Follow the frame chain up to the top document; the element is not
        # rendered if any hosting frame is disconnected or `display:none`.
        def in_non_rendered_frame?(element, style_for)
          doc = element.owner_document
          seen = 0
          while doc && (view = (doc.default_view if doc.respond_to?(:default_view))) &&
                (frame = view.frame_element) && (seen += 1) < MAX_FRAME_DEPTH
            return true if frame.respond_to?(:is_connected?) && !frame.is_connected?
            return true if style_for.call(frame)["display"] == "none"

            doc = frame.owner_document
          end
          false
        end
      end
    end
  end
end
