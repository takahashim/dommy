# frozen_string_literal: true

module Dommy
  module Internal
    module SelectorAST
      Specificity = Struct.new(:a, :b, :c) do
        def +(other)
          self.class.new(a + other.a, b + other.b, c + other.c)
        end

        def to_a = [a, b, c]

        def <=>(other)
          to_a <=> other.to_a
        end
      end

      ZERO = Specificity.new(0, 0, 0).freeze
      ID = Specificity.new(1, 0, 0).freeze
      CLASS = Specificity.new(0, 1, 0).freeze
      TYPE = Specificity.new(0, 0, 1).freeze

      SelectorList = Struct.new(:selectors) do
        def specificity
          selectors.map(&:specificity).max || ZERO
        end
      end

      ComplexSelector = Struct.new(:parts) do
        def rightmost = parts.last&.compound

        def pseudo_element
          rightmost&.pseudo_element
        end

        def pseudo_element?
          !pseudo_element.nil?
        end

        def without_pseudo_element
          return self unless pseudo_element?

          duped = parts.map { |part| Part.new(part.combinator, part.compound) }
          last = duped.last
          last.compound = last.compound.without_pseudo_element
          self.class.new(duped)
        end

        def specificity
          parts.reduce(ZERO) { |sum, part| sum + part.compound.specificity }
        end
      end

      Part = Struct.new(:combinator, :compound)
      RelativeSelector = Struct.new(:leading_combinator, :complex)

      CompoundSelector = Struct.new(:type, :subclass_selectors, :pseudo_element) do
        def without_pseudo_element
          self.class.new(type, subclass_selectors, nil)
        end

        def specificity
          sum = type ? type.specificity : ZERO
          subclass_selectors.each { |selector| sum += selector.specificity }
          sum += pseudo_element.specificity if pseudo_element
          sum
        end
      end

      TypeSelector = Struct.new(:namespace, :name) do
        def specificity = TYPE
      end

      UniversalSelector = Struct.new(:namespace) do
        def specificity = ZERO
      end

      IdSelector = Struct.new(:value) do
        def specificity = ID
      end

      ClassSelector = Struct.new(:value) do
        def specificity = CLASS
      end

      AttributeSelector = Struct.new(:namespace, :name, :matcher, :value, :case_flag) do
        def specificity = CLASS
      end

      PseudoClass = Struct.new(:name, :argument) do
        def specificity
          case name
          when "is", "not", "has"
            argument_specificity
          when "where"
            ZERO
          when "nth-child", "nth-last-child"
            CLASS + (argument&.of_selector_list&.specificity || ZERO)
          else
            CLASS
          end
        end

        private

        def argument_specificity
          if argument.respond_to?(:specificity)
            argument.specificity
          elsif argument.respond_to?(:map)
            argument.map { |item| item.respond_to?(:complex) ? item.complex.specificity : ZERO }.max || ZERO
          else
            ZERO
          end
        end
      end

      PseudoElement = Struct.new(:name, :argument) do
        def specificity = TYPE
      end

      NthExpression = Struct.new(:a, :b, :of_selector_list)
    end
  end
end
