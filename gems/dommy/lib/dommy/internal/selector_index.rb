# frozen_string_literal: true

module Dommy
  module Internal
    # A by-id / by-class / by-tag index over a document's backend element tree,
    # in document order. It turns a fast_query pre-filter from an O(tree) walk
    # ("visit every node, test it") into an O(matches) lookup ("here are the nodes
    # with class X"). Built once and memoized per DOM generation
    # (Document#style_generation) — a mutation invalidates it, and the NEXT query
    # rebuilds it, so on a page that fires many queries between mutations (jQuery
    # `$.find` storms) it is a big win, while a build costs the same single tree
    # walk it replaces, so it never loses to the plain walk.
    #
    # Works for ELEMENT-scoped queries too (jQuery's `.find` is `el.querySelectorAll`):
    # each element gets a pre-order interval [enter, exit] during the build, so a
    # candidate is inside a scope element's subtree iff its `enter` falls in the
    # scope's (enter, exit] — an O(candidates) range test, no per-node ancestor
    # walk. Candidates are stored as [enter, node] in document order.
    #
    # Holds backend nodes (never wrapped); the caller wraps only candidates and
    # still runs the authoritative #matches?, so the index need only be a SUPERSET
    # (tag matching is case-insensitive here; exact case / namespace stays
    # #matches?'s job).
    class SelectorIndex
      EMPTY = [].freeze

      def self.build(backend_doc)
        new.tap { |index| index.populate(backend_doc) }
      end

      def initialize
        @by_id = {}
        @by_class = {}
        @by_tag = {}
        @extent = {} # node pointer_id => [enter, exit] pre-order interval
        @counter = 0
      end

      # Walk the backend element tree in document order, numbering each element and
      # recording it under its id / classes / tag.
      def populate(node)
        child = node.first_element_child
        while child
          enter = (@counter += 1)
          record(child, enter)
          populate(child)
          @extent[child.pointer_id] = [enter, @counter]
          child = child.next_element
        end
        self
      end

      # Backend nodes for an indexable pre-filter ([:id|:class|:type, value]),
      # optionally restricted to `scope_node`'s subtree; nil when the index can't
      # serve it (a non-indexable :attr, or a scope it doesn't know) so the caller
      # falls back to the walk.
      def candidates(prefilter, scope_node = nil)
        entries = entries_for(prefilter)
        return nil unless entries

        if scope_node.nil?
          entries.map { |_enter, node| node }
        else
          ext = @extent[scope_node.pointer_id]
          return nil unless ext # detached / unknown scope -> let the caller walk

          lo, hi = ext
          entries.each_with_object([]) { |(enter, node), out| out << node if enter > lo && enter <= hi }
        end
      end

      # The pre-order `enter` number of a backend node (its position), or nil if
      # the node isn't in this index (detached / unknown).
      def enter_of(node)
        ext = @extent[node.pointer_id]
        ext && ext[0]
      end

      # Is there an indexed element matching `prefilter` whose subtree contains
      # the element at pre-order position `enter_l` — i.e. does that element have
      # an ANCESTOR matching the prefilter? Answered in O(log) via a prefix-max of
      # the matching elements' `exit` over their (sorted) `enter`s: an interval
      # [enter, exit] contains enter_l iff enter < enter_l <= exit, and by the
      # pre-order property that element is then an ancestor. Used to settle a
      # descendant combinator's leftmost compound without walking ancestors.
      def any_ancestor?(prefilter, enter_l)
        enters, max_exits = prefix_max_exit(prefilter)
        return false unless enters

        # last index with enters[i] < enter_l
        gte = enters.bsearch_index { |enter| enter >= enter_l } || enters.length
        i = gte - 1
        i >= 0 && max_exits[i] >= enter_l
      end

      private

      # [sorted enters, running-max exits] for an indexable prefilter, memoized
      # per prefilter for this generation, or nil when nothing matches. The first
      # call is O(matches) (touches only the matching elements, never the tree);
      # later calls reuse it.
      def prefix_max_exit(prefilter)
        (@prefix_cache ||= {})[prefilter] ||= begin
          entries = entries_for(prefilter)
          if entries.nil? || entries.empty?
            [nil, nil]
          else
            enters = []
            max_exits = []
            running = -1
            entries.each do |enter, node|
              ext = @extent[node.pointer_id]
              exit_pos = ext ? ext[1] : enter
              running = exit_pos if exit_pos > running
              enters << enter
              max_exits << running
            end
            [enters, max_exits]
          end
        end
      end

      def entries_for(prefilter)
        kind, value = prefilter
        case kind
        when :id then @by_id[value] || EMPTY
        when :class then @by_class[value] || EMPTY
        when :type then @by_tag[value.to_s.downcase] || EMPTY
        end
      end

      def record(bnode, enter)
        name = bnode.name
        (@by_tag[name.downcase] ||= []) << [enter, bnode] if name && !name.empty?

        id = bnode["id"]
        (@by_id[id] ||= []) << [enter, bnode] if id && !id.empty?

        klass = bnode["class"]
        return if klass.nil? || klass.empty?

        klass.split(/\s+/).each { |token| (@by_class[token] ||= []) << [enter, bnode] unless token.empty? }
      end
    end
  end
end
