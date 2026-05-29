# frozen_string_literal: true

module Dommy
  module Internal
    # Manages <template> element content fragments.
    # When HTML contains <template>X</template>, the inner content X is
    # detached and stored in a separate DocumentFragment, accessed via
    # the element's `content` property (per HTML spec).
    #
    # Keeping these fragments off-document is what makes template content
    # invisible to querySelector, getElementById, etc., on the main tree.
    class TemplateContentRegistry
      def initialize(document)
        @document = document
        # template_node.object_id → Nokogiri fragment
        @fragments = {}
      end

      # Parse HTML into a fragment and attach it as the template's content.
      # Drops any pre-existing direct children of the template element.
      def attach(template_element, html)
        template_element.__dommy_backend_node__.children.each(&:unlink)
        fragment = @document.nokogiri_doc.fragment(html.to_s)
        @fragments[template_element.__dommy_backend_node__.object_id] = fragment
        fragment
      end

      # Get the wrapped Fragment for a template element, seeding from
      # the template's current children if not previously migrated.
      def fragment_for(template_element)
        fragment = @fragments[template_element.__dommy_backend_node__.object_id]
        fragment ||= seed(template_element)
        @document.wrap_node(fragment)
      end

      # Raw (Nokogiri) fragment lookup by Nokogiri node — used by
      # internal traversal to skip template-content sub-trees.
      def raw_fragment_for(nokogiri_node)
        @fragments[nokogiri_node.object_id]
      end

      def inner_html_of(template_element)
        fragment = @fragments[template_element.__dommy_backend_node__.object_id]
        return "" unless fragment

        fragment.children.map(&:to_html).join
      end

      def has_content?(nokogiri_node)
        @fragments.key?(nokogiri_node.object_id)
      end

      # Direct register — called after manual fragment construction
      # (e.g., when seeding from existing template children).
      def store(template_node, fragment)
        @fragments[template_node.object_id] = fragment
      end

      # Walk a Nokogiri subtree, finding <template> elements whose
      # children are still direct (not yet migrated to a fragment), and
      # migrate each one. Called after innerHTML / fragment-parsing to
      # keep template content out of the main tree.
      def migrate_descendants(root)
        targets = []
        targets << root if template_needing_migration?(root)
        root.traverse do |node|
          targets << node if template_needing_migration?(node)
        end

        targets.uniq.each { |t| migrate_one(t) }
      end

      private

      def template_needing_migration?(node)
        return false unless node.respond_to?(:name) && node.name == "template"

        !has_content?(node)
      end

      def seed(template_element)
        migrate_one(template_element.__dommy_backend_node__)
        @fragments[template_element.__dommy_backend_node__.object_id]
      end

      def migrate_one(template_node)
        fragment = @document.nokogiri_doc.fragment("")
        template_node.children.to_a.each do |child|
          child.unlink
          fragment.add_child(child)
        end

        @fragments[template_node.object_id] = fragment
      end
    end
  end
end
