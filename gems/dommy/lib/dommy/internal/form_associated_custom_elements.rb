# frozen_string_literal: true

module Dommy
  module Internal
    # Form-associated custom elements (HTML §4.13.7): an autonomous custom
    # element whose definition says `static formAssociated = true` is a listed,
    # labelable, submittable, resettable form-associated element. This keeps
    # the parts of that the form code asks about — which elements they are, the
    # entries they submit — and the reactions their form owner and disabled
    # state call for: formAssociatedCallback when the form owner changes,
    # formDisabledCallback when the disabled state does, formResetCallback when
    # the form owner is reset.
    module FormAssociatedCustomElements
      # The local names of every form-associated definition, so the form code
      # can find their elements by selector.
      @local_names = Set.new

      # The constraint validation surface a form-associated custom element
      # shares with the built-in controls (what a form's checkValidity() and
      # `:invalid` / `:valid` ask), answered from its ElementInternals.
      module Behavior
        def will_validate
          internals = __internal_element_internals__
          internals ? !internals.barred? : (!__internal_actually_disabled__ && closest("datalist").nil?)
        end

        def validity
          __internal_element_internals__&.validity || ValidityState.new(nil)
        end

        def __internal_satisfies_constraints__?
          internals = __internal_element_internals__
          internals.nil? || internals.validity_flags_clear?
        end

        def __internal_fire_invalid__
          dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true).__internal_mark_trusted__)
        end
      end

      class << self
        def register(definition)
          @local_names << definition.local_name if definition.form_associated?
        end

        def any? = !@local_names.empty?

        # `selector` widened to the elements of a form-associated definition
        # (which are then filtered with #face?).
        def selector(base)
          return base if @local_names.empty?

          ([base] + @local_names.map { |name| ::Dommy::CSSNamespace.escape(name) }).join(", ")
        end

        def face?(element)
          element.respond_to?(:__internal_form_associated_custom__?) && element.__internal_form_associated_custom__?
        end

        # A form-associated custom element's form owner and disabled state
        # (HTML "reset the form owner", and the disabled-state change), each
        # enqueueing its callback when it changed. Only for a custom one: an
        # element still being upgraded gets them from the upgrade.
        def refresh(element)
          return unless face?(element) && element.__internal_ce_custom__?

          data = element.__internal_ce_data__
          form = element.__internal_form_owner__
          unless same_node?(form, data.form_owner)
            data.form_owner = form
            CEReactions.enqueue_callback(element, "formAssociatedCallback", [form])
          end
          disabled = element.__internal_actually_disabled__ ? true : false
          return if disabled == (data.disabled ? true : false)

          data.disabled = disabled
          CEReactions.enqueue_callback(element, "formDisabledCallback", [disabled])
        end

        # #refresh for each form-associated custom element in the subtree
        # rooted at backend node `root`.
        def refresh_subtree(document, root)
          return unless any?

          NodeTraversal.subtree_nodes(root).each do |node|
            next unless node.element? && @local_names.include?(node.name)

            element = document.__internal_peek_wrapper__(node)
            refresh(element) if element
          end
        end

        # HTML "reset" of a form: each form-associated custom element it owns
        # gets a formResetCallback reaction.
        def reset(form, controls)
          controls.each do |control|
            next unless face?(control) && control.__internal_ce_custom__?

            CEReactions.enqueue_callback(control, "formResetCallback", [])
          end
          form
        end

        # "Constructing the entry list" for a form-associated custom element:
        # its submission value under its name, or a FormData's entries.
        def append_entries(element, name, data)
          internals = element.__internal_element_internals__
          value = internals&.submission_value
          case value
          when nil then nil
          when FormData then value.entries.each { |k, v| data.append(k, v) }
          else
            data.append(name, value) unless name.nil? || name.empty?
          end
        end

        private

        def same_node?(a, b)
          return a.nil? && b.nil? if a.nil? || b.nil?

          a.__dommy_backend_node__.equal?(b.__dommy_backend_node__)
        end
      end
    end
  end
end
