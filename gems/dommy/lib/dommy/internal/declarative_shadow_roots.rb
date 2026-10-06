# frozen_string_literal: true

module Dommy
  module Internal
    # Declarative shadow roots, as a pass over what the parser built.
    #
    # The backend's HTML parser has no declarative shadow DOM: it parses a
    # `<template shadowrootmode>` as an ordinary template, with its children
    # in the template contents. HTML's tree builder, when its "allow
    # declarative shadow roots" is on, does instead — at the template start
    # tag ("in head" insertion mode) — attach a shadow root to the adjusted
    # current node and parse the template's children into it, never
    # inserting the template. This pass reproduces that result: it walks the
    # parsed nodes in tree order, which is the order the parser met the start
    # tags, and for each such template
    #
    #   - takes its parent as the declarative shadow host (the adjusted
    #     current node the template was inserted under). A template whose
    #     parent is not an element — the top of template contents (the
    #     adjusted current node was the enclosing template), or of a fragment
    #     parse (see below) — is left alone;
    #   - leaves the template in place when the host is already a shadow host
    #     (the first declarative template wins), or when attaching a shadow
    #     root throws (not a valid shadow host, a definition that disables
    #     shadow);
    #   - otherwise attaches one with the template's shadowrootmode,
    #     shadowrootdelegatesfocus, shadowrootserializable,
    #     shadowrootslotassignment and shadowrootclonable, and a null registry
    #     with shadowrootcustomelementregistry (else the host's document's);
    #     sets it declarative and available to element internals (and keep
    #     custom element registry null with that attribute), moves the template
    #     contents into it and drops the template.
    #
    # Template contents, and the shadow trees the pass makes, are walked too:
    # the parser attaches declarative shadow roots wherever it meets one.
    #
    # The fragment case: HTML's fragment parsing algorithm puts only its own
    # `html` root on the stack of open elements, so for a top-level template
    # the adjusted current node is the context element, and the spec text
    # would attach a shadow root to it. Browsers (and the WPT expectations)
    # leave such a template in place, and so does this pass, unless the
    # caller names a `top_host` — document.write, whose parser is the
    # document's own, where the template's adjusted current node really is
    # the element the markup goes into.
    #
    # Moving the contents is a representation fix-up, not a DOM mutation: in
    # the parser's tree they were never anywhere else. So it uses raw backend
    # moves, and queues no mutation records. What the parser does at the
    # time — a script's access mid-parse, the moment a MutationObserver sees
    # the host — cannot be reproduced by a pass that runs once parsing ends.
    #
    # Spec: https://html.spec.whatwg.org/multipage/parsing.html#parsing-main-inhead
    class DeclarativeShadowRoots
      MODES = %w[open closed].freeze

      # Run the pass over `root_bn`'s subtree (an element, a fragment, a
      # document). Returns the shadow roots it attached, in tree order.
      def self.attach(document, root_bn, top_host: nil)
        new(document).run(root_bn, top_host)
      end

      def initialize(document)
        @document = document
        @templates = document.__internal_template_registry__
        @attached = []
      end

      def run(root_bn, top_host)
        walk(root_bn, top_host) if candidate?(root_bn)
        @attached
      end

      private

      # Whether a `<template shadowrootmode>` is anywhere in the subtree,
      # template contents included — found by native queries, so a page with
      # none (most) is not walked.
      def candidate?(root_bn)
        return false unless root_bn.respond_to?(:css)
        return true if root_bn.element? && declarative_mode(root_bn)
        return true unless root_bn.css("template[shadowrootmode]").empty?

        templates = root_bn.css("template").to_a
        templates.unshift(root_bn) if root_bn.element? && @templates.template_node?(root_bn)
        templates.any? do |template|
          contents = @templates.existing_contents(template)
          contents && candidate?(contents)
        end
      end

      def walk(parent, host_for_children = nil)
        host_for_children ||= parent if parent.element?
        parent.children.to_a.each do |child|
          next unless child.element?

          if host_for_children && (mode = declarative_mode(child))
            shadow = attach(host_for_children, child, mode)
            if shadow
              walk(shadow.__dommy_backend_node__)
              next
            end
          end
          walk(child)
          next unless @templates.template_node?(child)

          contents = @templates.existing_contents(child)
          walk(contents) if contents
        end
      end

      # The template's shadowrootmode state, when it is open or closed.
      def declarative_mode(node)
        return nil unless @templates.template_node?(node)

        value = Backend.no_namespace_attribute_value(node, "shadowrootmode")
        return nil unless value

        mode = value.downcase(:ascii)
        mode if MODES.include?(mode)
      end

      def attach(host_bn, template, mode)
        host = @document.wrap_node(host_bn)
        return nil unless host.respond_to?(:__internal_attach_shadow_root__)
        return nil if host.__internal_shadow_root__

        keep_null = attribute?(template, "shadowrootcustomelementregistry")
        slot = Backend.no_namespace_attribute_value(template, "shadowrootslotassignment")
        begin
          shadow = host.__internal_attach_shadow_root__(
            mode: mode,
            delegates_focus: attribute?(template, "shadowrootdelegatesfocus"),
            serializable: attribute?(template, "shadowrootserializable"),
            slot_assignment: slot&.downcase(:ascii) == "manual" ? "manual" : "named",
            clonable: attribute?(template, "shadowrootclonable"),
            registry: keep_null ? nil : :document
          )
        rescue DOMException
          return nil
        end
        return nil unless shadow

        shadow.__internal_available_to_internals__ = true
        shadow.__internal_declarative__ = true
        shadow.__internal_keep_registry_null__ = keep_null
        shadow.__internal_parsed_before__ = template.next_sibling
        # Where the merge below leaves the text that followed the template.
        shadow.__internal_parsed_before__ = template.previous_sibling if text?(template.previous_sibling) && text?(template.next_sibling)
        move_contents(template, shadow.__dommy_backend_node__)
        drop_template(template)
        @attached << shadow
        shadow
      end

      # The template was never in the tree, so the parser appended the text
      # on either side of it to one Text node.
      def drop_template(template)
        before = template.previous_sibling
        after = template.next_sibling
        template.unlink
        return unless text?(before) && text?(after)

        before.content = before.content + after.content
        after.unlink
      end

      def text?(node) = node.is_a?(Backend.text_class) && !node.is_a?(Backend.cdata_class)

      def attribute?(node, name) = !Backend.no_namespace_attribute_value(node, name).nil?

      def move_contents(template, fragment)
        contents = @templates.existing_contents(template)
        return unless contents

        contents.children.to_a.each do |child|
          child.unlink
          fragment.add_child(child)
        end
      end
    end
  end
end
