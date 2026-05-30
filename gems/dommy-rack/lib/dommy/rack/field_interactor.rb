# frozen_string_literal: true

module Dommy
  module Rack
    # Drives form fields in the current document: fills text inputs, toggles
    # radios / checkboxes, selects options, attaches files. Pure DOM mutation —
    # it locates fields via a Locator and mutates the live Dommy elements, but
    # issues no requests (Session turns a subsequent submit into navigation).
    class FieldInteractor
      def initialize(finder, document)
        @finder = finder
        @document = document
      end

      def fill_in(locator, with:)
        field = @finder.find_field(locator)
        field.value = with.to_s
        field
      end

      def choose(locator)
        radio = @finder.find_field(locator)
        clear_radio_group(radio)
        radio.checked = true
        radio
      end

      def check(locator)
        box = @finder.find_field(locator)
        box.checked = true
        box
      end

      def uncheck(locator)
        box = @finder.find_field(locator)
        box.checked = false
        box
      end

      def attach_file(locator, path)
        input = @finder.find_field(locator)
        raise FileNotFoundError, "no such file: #{path}" unless ::File.exist?(path)

        file = Dommy::File.new(
          [::File.binread(path)], ::File.basename(path), "type" => FileUpload.mime_type_for(path)
        )
        input.__driver_set_files__([file])
        input
      end

      def select(value, from:)
        select_el = @finder.find_field(from)
        option = @finder.find_option(select_el, value)
        raise ElementNotFoundError, "no option #{value.inspect} in #{from.inspect}" unless option

        select_el.options.each { |o| o.remove_attribute("selected") } unless select_el.multiple
        option.set_attribute("selected", "")
        select_el
      end

      def unselect(value, from:)
        select_el = @finder.find_field(from)
        option = @finder.find_option(select_el, value)
        option&.remove_attribute("selected")
        select_el
      end

      private

      def clear_radio_group(radio)
        name = radio.get_attribute("name")
        return unless name

        scope = radio.closest("form") || @document
        scope.query_selector_all("input[type='radio']").each do |r|
          r.checked = false if r.get_attribute("name") == name
        end
      end
    end
  end
end
