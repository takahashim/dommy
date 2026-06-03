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
        # Backend.identity_key(template_node) → backend fragment
        @fragments = {}
      end

      # Parse HTML into a fragment and attach it as the template's content.
      # Drops any pre-existing direct children of the template element.
      def attach(template_element, html)
        Backend.template_content_nodes(template_element.__dommy_backend_node__).each(&:unlink)
        fragment = @document.nokogiri_doc.fragment(html.to_s)
        @fragments[Backend.identity_key(template_element.__dommy_backend_node__)] = fragment
        fragment
      end

      # Get the wrapped Fragment for a template element, seeding from
      # the template's current children if not previously migrated.
      def fragment_for(template_element)
        fragment = @fragments[Backend.identity_key(template_element.__dommy_backend_node__)]
        fragment ||= seed(template_element)
        @document.wrap_node(fragment)
      end

      # Raw (Nokogiri) fragment lookup by Nokogiri node — used by
      # internal traversal to skip template-content sub-trees.
      def raw_fragment_for(nokogiri_node)
        @fragments[Backend.identity_key(nokogiri_node)]
      end

      def inner_html_of(template_element)
        fragment = @fragments[Backend.identity_key(template_element.__dommy_backend_node__)]
        return "" unless fragment

        fragment.children.map(&:to_html).join
      end

      def has_content?(nokogiri_node)
        @fragments.key?(Backend.identity_key(nokogiri_node))
      end

      # Direct register — called after manual fragment construction
      # (e.g., when seeding from existing template children).
      def store(template_node, fragment)
        @fragments[Backend.identity_key(template_node)] = fragment
      end

      # Walk a Nokogiri subtree, finding <template> elements whose
      # children are still direct (not yet migrated to a fragment), and
      # migrate each one. Called after the initial page parse / innerHTML /
      # fragment-parsing to keep template content out of the main tree.
      #
      # Uses a C-accelerated `css` query for descendants (rather than a
      # Ruby-level full traverse) so eager migration on every page parse is
      # cheap — a no-op fast path when the document has no <template>.
      def migrate_descendants(root)
        targets = []
        targets << root if template_needing_migration?(root)
        descendants =
          if root.respond_to?(:css)
            root.css("template")
          else
            [].tap { |acc| root.traverse { |node| acc << node } }
          end
        descendants.each { |node| targets << node if template_needing_migration?(node) }

        targets.uniq.each { |t| migrate_one(t) }
      end

      private

      def template_needing_migration?(node)
        return false unless node.respond_to?(:name) && node.name == "template"

        !has_content?(node)
      end

      def seed(template_element)
        migrate_one(template_element.__dommy_backend_node__)
        @fragments[Backend.identity_key(template_element.__dommy_backend_node__)]
      end

      def migrate_one(template_node)
        fragment = @document.nokogiri_doc.fragment("")
        Backend.template_content_nodes(template_node).each do |child|
          child.unlink
          fragment.add_child(child)
        end

        @fragments[Backend.identity_key(template_node)] = fragment
      end
    end
  end
end
