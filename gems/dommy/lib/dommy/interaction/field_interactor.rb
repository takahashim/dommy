# frozen_string_literal: true

module Dommy
  module Interaction
    # Drives form fields: fills text inputs, toggles radios / checkboxes,
    # selects options, attaches files. Mutates the live Dommy elements AND fires
    # the browser's input/change (and focus) events so JS handlers (React
    # onChange, Stimulus, …) react. The value is written directly on the element
    # — the React "native setter" path — so a framework's value tracker sees the
    # change rather than swallowing it.
    class FieldInteractor
      # Minimal extension → MIME map for attach_file (core stays Rack-free).
      MIME_TYPES = {
        ".txt" => "text/plain", ".html" => "text/html", ".htm" => "text/html",
        ".json" => "application/json", ".csv" => "text/csv", ".xml" => "application/xml",
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif" => "image/gif", ".pdf" => "application/pdf"
      }.freeze

      def initialize(finder, document)
        @finder = finder
        @document = document
      end

      def fill_in(locator, with:)
        field = @finder.find_field(locator)
        EventSynthesis.focus(field)
        field.value = with.to_s
        EventSynthesis.input(field, with.to_s)
        EventSynthesis.change(field)
        field
      end

      def choose(locator)
        radio = @finder.find_field(locator)
        clear_radio_group(radio)
        radio.checked = true
        EventSynthesis.input(radio)
        EventSynthesis.change(radio)
        radio
      end

      def check(locator)
        toggle(@finder.find_field(locator), true)
      end

      def uncheck(locator)
        toggle(@finder.find_field(locator), false)
      end

      def attach_file(locator, path)
        input = @finder.find_field(locator)
        raise FileNotFoundError, "no such file: #{path}" unless ::File.exist?(path)

        file = Dommy::File.new(
          [::File.binread(path)], ::File.basename(path), "type" => mime_type_for(path)
        )
        input.__driver_set_files__([file])
        EventSynthesis.change(input)
        input
      end

      def select(value, from:)
        select_el = @finder.find_field(from)
        option = @finder.find_option(select_el, value)
        raise ElementNotFoundError, "no option #{value.inspect} in #{from.inspect}" unless option

        select_el.options.each { |o| o.remove_attribute("selected") } unless select_el.multiple
        option.set_attribute("selected", "")
        EventSynthesis.input(select_el)
        EventSynthesis.change(select_el)
        select_el
      end

      def unselect(value, from:)
        select_el = @finder.find_field(from)
        option = @finder.find_option(select_el, value)
        return select_el unless option

        option.remove_attribute("selected")
        EventSynthesis.input(select_el)
        EventSynthesis.change(select_el)
        select_el
      end

      TEXT_ENTRY_INPUT_TYPES = %w[text search email url tel password number].freeze

      def text_entry_field?(element)
        return true if element.local_name == "textarea"
        return false unless element.local_name == "input"

        type = (element.get_attribute("type") || "text").downcase
        TEXT_ENTRY_INPUT_TYPES.include?(type)
      end

      # Append `text` to a text-entry field's value (no caret/selection model:
      # insertion is at the end), firing cancelable beforeinput then input.
      # Returns whether the field accepted the insertion (false for a
      # non-text-entry field or a prevented beforeinput) — used by Driver's
      # send_keys to decide whether a key's default action ran.
      def insert_text(element, text)
        return false unless text_entry_field?(element)
        return false if EventSynthesis.beforeinput(element, text, "insertText")

        element.value = element.value.to_s + text
        EventSynthesis.input(element, text)
        true
      end

      # Delete the last character of a text-entry field's value. Same return
      # contract as #insert_text.
      def backspace(element)
        return false unless text_entry_field?(element)

        value = element.value.to_s
        return false if value.empty?
        return false if EventSynthesis.beforeinput(element, nil, "deleteContentBackward")

        element.value = value[0...-1]
        EventSynthesis.input(element, nil, "deleteContentBackward")
        true
      end

      # Show composition state `update` in a text-entry field (value becomes
      # base + update) with the insertCompositionText beforeinput/input pair.
      # No beforeinput veto: composition inputs are not cancelable (spec).
      # Same return contract as #insert_text.
      def set_composition_text(element, base, update)
        return false unless text_entry_field?(element)

        element.value = base + update
        EventSynthesis.composition_input(element, update)
        true
      end

      # Cancel a composition: restore the field's pre-composition value and
      # fire a deleteCompositionText input. Same return contract.
      def cancel_composition_text(element, base)
        return false unless text_entry_field?(element)

        element.value = base
        EventSynthesis.input(element, nil, "deleteCompositionText")
        true
      end

      private

      def toggle(box, checked)
        return box if box.checked == checked

        box.checked = checked
        # React (and other frameworks) detect checkbox/radio changes from the
        # `click` event, not `change` — its ChangeEventPlugin uses
        # shouldUseClickEvent for these inputs. Fire the full click sequence so
        # the synthetic onChange runs, then input/change for plain listeners.
        EventSynthesis.click(box)
        EventSynthesis.input(box)
        EventSynthesis.change(box)
        box
      end

      def mime_type_for(path)
        MIME_TYPES.fetch(::File.extname(path).downcase, "application/octet-stream")
      end

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
