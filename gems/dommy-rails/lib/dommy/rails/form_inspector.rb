# frozen_string_literal: true

require "dommy/internal/element_matching"
require_relative "url_matcher"

module Dommy
  module Rails
    module FormInspector
      module_function

      def matches?(document, action: nil, method: nil, model: nil)
        forms = Internal::ElementMatching.find_forms(document, action: action && UrlMatcher.new(action), method: method)
        forms = forms.select { |form| form_has_model?(form, model_name_for(model)) } if model
        forms.any?
      end

      def method_override(form)
        hidden = form.query_selector("input[type='hidden'][name='_method']")
        hidden ? hidden.get_attribute("value") : nil
      end

      def authenticity_token(form)
        input = form.query_selector("input[type='hidden'][name='authenticity_token']")
        input ? input.get_attribute("value") : nil
      end

      def model_name_for(model)
        if model.respond_to?(:model_name)
          model.model_name.param_key
        elsif model.respond_to?(:to_model)
          model.to_model.model_name.param_key
        else
          # No ActiveSupport fallback: dommy-rails depends only on dommy,
          # and Rails form helpers require these methods too.
          raise ArgumentError,
            "model: expects an object responding to #model_name or #to_model, got #{model.class}"
        end
      end

      # A Rails model form scopes its field names under the model's
      # param key (e.g. name="article[title]").
      def form_has_model?(form, model_name)
        prefix = "#{model_name}["
        form.query_selector_all("input, textarea, select").to_a.any? do |field|
          field.get_attribute("name").to_s.start_with?(prefix)
        end
      end

      private_class_method :model_name_for, :form_has_model?
    end
  end
end
