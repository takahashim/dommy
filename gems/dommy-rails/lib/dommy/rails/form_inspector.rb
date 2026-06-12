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
          model.class.name.underscore
        end
      end

      # A Rails model form scopes its field names under the model's
      # param key (e.g. name="article[title]").
      def form_has_model?(form, model_name)
        fields = form.query_selector_all("input[name^='#{model_name}['], textarea[name^='#{model_name}['], select[name^='#{model_name}[']")
        fields.any?
      end

      private_class_method :model_name_for, :form_has_model?
    end
  end
end
