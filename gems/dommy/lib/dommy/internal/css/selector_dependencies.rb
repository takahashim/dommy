# frozen_string_literal: true

require_relative "../selector_ast"

module Dommy
  module Internal
    module CSS
      # What the indexed selectors read, so a mutation can be judged: will it
      # change what anything matches, or can the cascade caches stand?
      #
      # Three INDEPENDENT axes, because they are announced by three different
      # kinds of mutation:
      #
      #   attributes  — `[data-x]`, `.c`, `:checked` (which reads `checked`,
      #                 `selected`, `type`, `name`)
      #   text        — `:empty`, whose truth flips on a characterData edit
      #                 that no attribute mutation accompanies
      #   IDL value   — `:valid` / `:in-range` / `:placeholder-shown`, which
      #                 track a control's value: typing, `input.value =`, a form
      #                 reset all change it with no attribute behind them
      #
      # An AST node this walker does not recognize is treated as reading
      # everything (#attribute? then answers true for any name). Correctness
      # over cache hits — a missed dependency is a stale style, a spurious one
      # is only a rebuild.
      class SelectorDependencies
        # Attribute reads behind each state pseudo-class. A pseudo-class whose
        # state has its own invalidation path (tree position -> childList
        # bump; focus/hover/checkedness -> selector-state bump) maps to [].
        PSEUDO_CLASS_ATTR_DEPS = {
          "scope" => [], "root" => [],
          "first-child" => [], "last-child" => [], "only-child" => [],
          "first-of-type" => [], "last-of-type" => [], "only-of-type" => [],
          "focus" => [], "focus-visible" => [], "focus-within" => [],
          "hover" => [], "active" => [], "visited" => [],
          "link" => %w[href], "any-link" => %w[href],
          "checked" => %w[checked selected type name],
          "enabled" => %w[disabled type], "disabled" => %w[disabled type],
          "required" => %w[required], "optional" => %w[required],
          "read-only" => %w[readonly disabled contenteditable type],
          "read-write" => %w[readonly disabled contenteditable type],
          "lang" => %w[lang xml:lang], "dir" => %w[dir],
          "target" => %w[id], "target-within" => %w[id],
        }.freeze

        TEXT_SENSITIVE_PSEUDOS = %w[empty blank].freeze
        # Pseudo-classes that read a control's IDL value, which changes with no
        # attribute mutation behind it (typing, `value=`, a form reset).
        VALUE_SENSITIVE_PSEUDOS = %w[
          valid invalid user-valid user-invalid in-range out-of-range placeholder-shown
        ].freeze
        NTH_PSEUDOS = %w[nth-child nth-last-child nth-of-type nth-last-of-type].freeze
        LOGICAL_PSEUDOS = %w[is where not has host host-context].freeze

        def initialize
          # "style" is always a dependency: the cascade reads the style
          # attribute directly, whatever the selectors say.
          @attributes = {"style" => true}
          @all_attributes = false
          @text_sensitive = false
          @value_sensitive = false
        end

        # Record everything `node` (a selector AST, or an Array of relative
        # selectors as :has() carries them) can read.
        def observe(node)
          return if saturated? || node.nil?

          case node
          when Array # :has() carries its RelativeSelectors as a plain Array
            node.each { |entry| observe(entry) }
          when Internal::SelectorAST::SelectorList
            node.selectors.each { |selector| observe(selector) }
          when Internal::SelectorAST::RelativeSelector
            observe(node.complex)
          when Internal::SelectorAST::ComplexSelector
            node.parts.each { |part| observe(part.compound) }
          when Internal::SelectorAST::CompoundSelector
            node.subclass_selectors.each { |selector| observe(selector) }
            observe_pseudo_element(node.pseudo_element) if node.pseudo_element
          when Internal::SelectorAST::TypeSelector, Internal::SelectorAST::UniversalSelector
            nil
          when Internal::SelectorAST::IdSelector
            add_attribute("id")
          when Internal::SelectorAST::ClassSelector
            add_attribute("class")
          when Internal::SelectorAST::AttributeSelector
            add_attribute(node.name)
          when Internal::SelectorAST::PseudoClass
            observe_pseudo_class(node)
          else
            @all_attributes = true
          end
        end

        # Whether a mutation of attribute `name` can change what any observed
        # selector matches.
        def attribute?(name)
          @all_attributes || @attributes.key?(name.to_s.downcase)
        end

        # Whether any observed selector reads text content (:empty), so an
        # emptiness-flipping characterData edit must invalidate the cascade.
        def text_sensitive? = @text_sensitive

        # Whether any observed selector reads a form control's IDL value, so
        # assigning `input.value` — which mutates no attribute — must too.
        def value_sensitive? = @value_sensitive

        private

        # Nothing left to learn: every axis is already maxed. The walk stops
        # only when ALL of them are, since an unmapped pseudo that set
        # @all_attributes must not hide a later `:empty` from text-sensitivity.
        def saturated? = @all_attributes && @text_sensitive && @value_sensitive

        def observe_pseudo_class(pseudo)
          name = pseudo.name
          # Orthogonal to the attribute axis below: :invalid both reads form
          # attributes (falling through to @all_attributes) and tracks the IDL
          # value, which no attribute mutation announces.
          @value_sensitive = true if VALUE_SENSITIVE_PSEUDOS.include?(name)
          if TEXT_SENSITIVE_PSEUDOS.include?(name)
            @text_sensitive = true
          elsif NTH_PSEUDOS.include?(name)
            of_list = pseudo.argument.respond_to?(:of_selector_list) && pseudo.argument.of_selector_list
            observe(of_list) if of_list
          elsif LOGICAL_PSEUDOS.include?(name)
            observe(pseudo.argument) if pseudo.argument
          elsif (deps = PSEUDO_CLASS_ATTR_DEPS[name])
            deps.each { |dep| add_attribute(dep) }
          else
            # :valid/:invalid read half the form attributes; anything not
            # mapped is treated the same way.
            @all_attributes = true
          end
        end

        # A pseudo-element gates on presence, not attribute values — except
        # ::slotted (slot assignment follows the slot/name attributes) and
        # ::part (the part token list).
        def observe_pseudo_element(pseudo)
          case pseudo.name
          when "slotted"
            add_attribute("slot")
            add_attribute("name")
            observe(pseudo.argument) unless pseudo.argument.is_a?(Array)
          when "part"
            add_attribute("part")
            add_attribute("exportparts")
          end
        end

        def add_attribute(name)
          # Once every attribute already invalidates, individual names are
          # moot — the walk continues only to find text-sensitive pseudos.
          @attributes[name.to_s.downcase] = true unless @all_attributes
        end
      end
    end
  end
end
