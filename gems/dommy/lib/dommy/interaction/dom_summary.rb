# frozen_string_literal: true

module Dommy
  module Interaction
    # Summarizes the user-facing controls of a DOM scope (a document or any
    # element with `query_selector_all`): the buttons, fields, links, and forms
    # a person would see. Engine-independent and scope-general — it backs the
    # finder's "available …" failure messages, the `Debug` facade, and failure
    # artifacts, and can be called directly on any document (e.g. a request
    # spec's `dom`).
    #
    #   Dommy::Interaction::DomSummary.buttons(document)
    #   #=> [{label: "Save", type: "submit", selector: "button[type=submit]"}]
    #   puts Dommy::Interaction::DomSummary.to_text(document)
    module DomSummary
      module_function

      # Submit-capable and plain buttons, as {label:, type:, selector:}.
      def buttons(scope)
        return [] unless scope

        scope.query_selector_all("button, input[type='submit'], input[type='image'], input[type='button'], input[type='reset']").map do |el|
          {label: button_label(el), type: presence(el.get_attribute("type")), selector: selector_for(el)}
        end
      end

      # Form fields, as {label:, name:, id:, type:, selector:}.
      def fields(scope)
        return [] unless scope

        scope.query_selector_all("input, textarea, select").reject { |el| hidden_input?(el) }.map do |el|
          {label: field_label(el, scope), name: presence(el.get_attribute("name")),
           id: presence(el.get_attribute("id")), type: field_type(el), selector: selector_for(el)}
        end
      end

      # Links with an href, as {text:, href:}.
      def links(scope)
        return [] unless scope

        scope.query_selector_all("a[href]").map do |el|
          {text: squish(el.text_content), href: el.get_attribute("href").to_s}
        end
      end

      # Forms, as {action:, method:, fields: [names]}.
      def forms(scope)
        return [] unless scope

        scope.query_selector_all("form").map do |form|
          {action: presence(form.get_attribute("action")), method: form_method(form),
           fields: fields(form).map { |f| f[:name] }.compact}
        end
      end

      # One-line descriptors for failure messages: `"Save" button[type=submit]`.
      def button_labels(scope) = buttons(scope).map { |b| "#{quote(b[:label])} #{b[:selector]}".strip }
      def field_labels(scope) = fields(scope).map { |f| "#{quote(f[:label] || f[:name])} #{f[:selector]}".strip }
      def link_labels(scope) = links(scope).map { |l| "#{quote(l[:text])} -> #{l[:href]}" }

      # A readable, sectioned summary of the scope's controls (used by the
      # `Debug` facade and failure artifacts).
      def to_text(scope)
        sections = {
          "Forms" => forms(scope).map { |f| "#{(f[:method] || "get").upcase} #{f[:action] || "(self)"} [#{f[:fields].join(", ")}]" },
          "Links" => link_labels(scope),
          "Buttons" => button_labels(scope),
          "Fields" => field_labels(scope)
        }
        sections.reject { |_, rows| rows.empty? }
          .map { |name, rows| "#{name}:\n#{rows.map { |r| "  #{r}" }.join("\n")}" }
          .join("\n")
      end

      # --- label / descriptor helpers ---

      def button_label(el)
        if el.tag_name == "INPUT"
          presence(el.get_attribute("value")) || presence(el.get_attribute("alt")) || ""
        else
          squish(el.text_content)
        end
      end

      # Prefer an associated <label>, then aria-label, placeholder, name, id.
      def field_label(el, scope)
        label_caption(el, scope) || presence(el.get_attribute("aria-label")) ||
          presence(el.get_attribute("placeholder")) || presence(el.get_attribute("name")) ||
          presence(el.get_attribute("id"))
      end

      def label_caption(el, scope)
        id = presence(el.get_attribute("id"))
        wrapping = el.respond_to?(:closest) ? el.closest("label") : nil
        label = (id && scope.query_selector_all("label").find { |l| l.get_attribute("for") == id }) || wrapping
        label ? presence(squish(label.text_content)) : nil
      end

      def field_type(el)
        return el.tag_name.downcase unless el.tag_name == "INPUT"

        presence(el.get_attribute("type")) || "text"
      end

      def selector_for(el)
        tag = el.tag_name.downcase
        type = presence(el.get_attribute("type"))
        name = presence(el.get_attribute("name"))
        descriptor = tag
        descriptor += "[type=#{type}]" if type
        descriptor += "[name=#{name}]" if name
        descriptor
      end

      # Collapsed visible text of a scope. A Document has no text_content of its
      # own, so read its <body>.
      def text(scope)
        return "" unless scope

        node = scope.respond_to?(:body) ? scope.body : scope
        squish(node&.text_content)
      end

      def hidden_input?(el) = el.tag_name == "INPUT" && el.get_attribute("type") == "hidden"
      def form_method(form) = presence(form.get_attribute("method"))&.downcase
      def squish(text) = text.to_s.gsub(/\s+/, " ").strip
      def presence(value) = (value.nil? || value.to_s.empty?) ? nil : value
      def quote(value) = value.to_s.inspect
    end
  end
end
