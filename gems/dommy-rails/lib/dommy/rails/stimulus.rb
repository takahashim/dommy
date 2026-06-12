# frozen_string_literal: true

module Dommy
  module Rails
    module Stimulus
      module_function

      # ----- Scope-level predicates (any element in scope matches) -----

      def controller?(scope, name)
        scope.query_selector_all("[data-controller]").to_a.any? { |element| has_controller?(element, name) }
      end

      def action?(scope, action)
        scope.query_selector_all("[data-action]").to_a.any? { |element| has_action?(element, action) }
      end

      def target?(scope, controller, target)
        scope.query_selector_all("[data-#{controller}-target]").to_a.any? { |element| has_target?(element, controller, target) }
      end

      def value?(scope, controller, key, value)
        scope.query_selector_all("[data-#{controller}-#{key}-value]").to_a.any? { |element| has_value?(element, controller, key, value) }
      end

      # ----- Element-level predicates -----

      def has_controller?(element, name)
        controllers = element.get_attribute("data-controller").to_s.split
        controllers.include?(name.to_s)
      end

      def has_action?(element, action)
        actions = element.get_attribute("data-action").to_s.split
        actions.any? { |a| a == action.to_s || a.end_with?("->#{action}") }
      end

      def has_target?(element, controller, target)
        element.has_attribute?("data-#{controller}-target") &&
          element.get_attribute("data-#{controller}-target").to_s.split.include?(target.to_s)
      end

      def has_value?(element, controller, key, value)
        attr_name = "data-#{controller}-#{key}-value"
        return false unless element.has_attribute?(attr_name)
        element.get_attribute(attr_name).to_s == value.to_s
      end
    end
  end
end
