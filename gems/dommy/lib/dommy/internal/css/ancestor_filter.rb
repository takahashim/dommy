# frozen_string_literal: true

require_relative "../selector_ast"
require_relative "../infra"

module Dommy
  module Internal
    module CSS
      # A Bloom filter over the tags, ids and classes of an element's
      # ancestors, so a rule that needs an ancestor the element does not have
      # is dropped before it is matched (the rule-matching fast reject engines
      # call the ancestor filter). A rule's mask holds the keys of every
      # compound its descendant and child combinators put above the subject —
      # `.menu li a` needs a `.menu` and an `li` above the `a`, and
      # `:where(.space-y-4 > :not(:last-child))` a `.space-y-4`. An element
      # passes when its ancestors' filter holds every bit of the mask. A
      # filter can hold bits no ancestor put there (two keys sharing one), so
      # it can let a rule through to the matcher, never drop one that matches.
      module AncestorFilter
        BITS = 512
        ANCESTRAL_COMBINATORS = %i[descendant child].freeze
        # Pseudo-classes whose (single) selector argument the subject itself
        # must match, so that argument's ancestors are the subject's.
        MATCHES_ARGUMENT = %w[is where].freeze

        module_function

        # The mask of keys the ancestors of an element `complex` matches must
        # carry; 0 when it needs none. `fold` is the id / class folding of the
        # document (RuleIndex#bucket_key).
        def mask_for(complex, fold)
          ancestor_keys(complex, fold).reduce(0) { |mask, key| mask | bits(key) }
        end

        # The bits an element contributes to its descendants' filter.
        def element_bits(element, fold)
          mask = bits("t:#{element.local_name.to_s.downcase}")
          id = element.__internal_attribute_value__("id").to_s
          mask |= bits("##{fold.call(id)}") unless id.empty?
          classes = element.__internal_attribute_value__("class").to_s
          unless classes.empty?
            classes.split(Internal::Infra::ASCII_WHITESPACE).each do |token|
              mask |= bits(".#{fold.call(token)}") unless token.empty?
            end
          end
          mask
        end

        # A compound is an ancestor of the subject when the combinator right
        # after it is a descendant or child one: it is then an ancestor of the
        # compound on its right, which is the subject, an ancestor of it, or a
        # sibling of either — and the ancestors of a sibling are the
        # element's own. One followed by `+` or `~` is a sibling (of the
        # subject or of an ancestor of it), so `.a ~ .b .c` needs a `.b`
        # above the `.c`, not an `.a`.
        def ancestor_keys(complex, fold)
          parts = complex.parts
          keys = []
          (1...parts.size).each do |i|
            next unless ANCESTRAL_COMBINATORS.include?(parts[i].combinator)

            keys.concat(compound_keys(parts[i - 1].compound, fold))
          end
          parts.last.compound.subclass_selectors.each do |selector|
            argument = matched_argument(selector)
            keys.concat(ancestor_keys(argument, fold)) if argument
          end
          keys
        end

        def compound_keys(compound, fold)
          keys = []
          type = compound.type
          if type.is_a?(Internal::SelectorAST::TypeSelector) && type.name && type.name != "*"
            keys << "t:#{type.name.to_s.downcase}"
          end
          compound.subclass_selectors.each do |selector|
            case selector
            when Internal::SelectorAST::IdSelector then keys << "##{fold.call(selector.value)}"
            when Internal::SelectorAST::ClassSelector then keys << ".#{fold.call(selector.value)}"
            end
          end
          keys
        end

        # The one complex selector of `:is(...)` / `:where(...)`, or nil.
        def matched_argument(selector)
          return nil unless selector.is_a?(Internal::SelectorAST::PseudoClass)
          return nil unless MATCHES_ARGUMENT.include?(selector.name)

          list = selector.argument
          return nil unless list.is_a?(Internal::SelectorAST::SelectorList) && list.selectors.size == 1

          list.selectors.first
        end

        # Two bits per key, from its hash.
        def bits(key)
          hash = key.hash
          (1 << (hash % BITS)) | (1 << ((hash >> 16) % BITS))
        end

        private_class_method :ancestor_keys, :compound_keys, :matched_argument, :bits
      end
    end
  end
end
