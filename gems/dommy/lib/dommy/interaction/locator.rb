# frozen_string_literal: true

module Dommy
  module Interaction
    # Finds DOM elements within a document/scope by Capybara-style locators.
    # Pure querying: it raises ElementNotFoundError / AmbiguousElementError but
    # does not mutate the DOM or perform navigation. Shared by the Rack session
    # and the standalone Browser.
    class Locator
      def initialize(document)
        @document = document
      end

      # A form field by id, name, label text, placeholder, or aria-label.
      def find_field(locator)
        candidates = []
        by_id = @document.get_element_by_id(locator)
        candidates << by_id if by_id
        candidates.concat(by_name(locator))
        candidates.concat(label_targets(locator))
        candidates.concat(by_field_attribute("placeholder", locator))
        candidates.concat(by_field_attribute("aria-label", locator))
        resolve_single(candidates, locator)
      end

      # An <a> by visible text, id, title, or exact href.
      def find_link(locator)
        matches = @document.query_selector_all("a").select { |a| link_matches?(a, locator) }
        resolve_single(matches, locator)
      end

      # A submit-capable button by text, value, id, name, or alt.
      def find_button(locator)
        buttons = @document.query_selector_all(
          "button, input[type='submit'], input[type='image'], input[type='button']"
        )
        resolve_single(buttons.select { |b| button_matches?(b, locator) }, locator)
      end

      # The <option> of a select matching by visible text, then by value.
      def find_option(select_el, value)
        options = select_el.options.to_a
        options.find { |o| o.text_content.strip == value.to_s } ||
          options.find { |o| (o.get_attribute("value") || "").to_s == value.to_s }
      end

      # The form owning an element: an explicit `form` attribute, else the
      # nearest ancestor <form>.
      def form_for(element)
        form_id = element.get_attribute("form")
        if form_id && !form_id.empty?
          @document.get_element_by_id(form_id)
        else
          element.closest("form")
        end
      end

      private

      def by_name(locator)
        @document.query_selector_all("[name]").select { |e| e.get_attribute("name") == locator }
      end

      def by_field_attribute(attribute, value)
        @document.query_selector_all("input, textarea, select")
          .select { |e| e.get_attribute(attribute) == value }
      end

      def label_targets(locator)
        @document.query_selector_all("label")
          .select { |label| label.text_content.strip == locator }
          .map { |label| label_control(label) }
          .compact
      end

      def label_control(label)
        return label.control if label.respond_to?(:control) && label.control

        for_id = label.get_attribute("for")
        if for_id && !for_id.empty?
          @document.get_element_by_id(for_id)
        else
          label.query_selector("input, textarea, select")
        end
      end

      def link_matches?(anchor, locator)
        anchor.text_content.strip == locator ||
          anchor.get_attribute("id") == locator ||
          anchor.get_attribute("title") == locator ||
          anchor.get_attribute("href") == locator
      end

      def button_matches?(button, locator)
        if button.tag_name == "BUTTON"
          return true if button.text_content.strip == locator
        end
        button.get_attribute("value") == locator ||
          button.get_attribute("id") == locator ||
          button.get_attribute("name") == locator ||
          button.get_attribute("alt") == locator
      end

      def resolve_single(candidates, locator)
        unique = candidates.compact.uniq(&:__dommy_backend_node__)
        raise ElementNotFoundError, "no element matching #{locator.inspect}" if unique.empty?

        if unique.size > 1
          raise AmbiguousElementError, "#{unique.size} elements match #{locator.inspect}"
        end

        unique.first
      end
    end
  end
end
