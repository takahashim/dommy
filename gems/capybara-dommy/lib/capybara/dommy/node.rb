# frozen_string_literal: true

module Capybara
  module Dommy
    # Wraps a Dommy::Element as a Capybara driver node. Modeled on
    # Capybara::RackTest::Node: field setting mutates the Dommy::Element in the
    # live document, while link clicks and form submission delegate to the
    # dommy-rack session (which re-reads the same document at submit time).
    class Node < Capybara::Driver::Node
      OPTION_OWNER_XPATH = "./parent::*[self::optgroup | self::select | self::datalist]"
      DISABLED_BY_FIELDSET_XPATH =
        "./parent::fieldset[./@disabled] | " \
        "./ancestor::*[(not(./self::legend) or ./preceding-sibling::legend)][./parent::fieldset[./@disabled]]"

      def tag_name
        native.tag_name.downcase
      end

      def [](name)
        key = name.to_s
        # Capybara's validation_message filter reads the constraint-validation
        # DOM property, which never appears as a markup attribute.
        if key == "validationMessage" && native.respond_to?(:validation_message)
          return native.validation_message
        end

        # `checked` / `selected` reflect the live IDL property (current state),
        # not the content attribute (which is the *default*) — as WebDriver's
        # getAttribute does for these boolean attributes.
        if key == "checked" && native.respond_to?(:checked)
          return native.checked ? "true" : nil
        end
        if key == "selected" && native.respond_to?(:selected)
          return native.selected ? "true" : nil
        end

        native.get_attribute(key)
      end

      def value
        if select?
          native.multiple ? native.selected_options.map(&:value) : native.value
        elsif checkable?
          native.has_attribute?("value") ? native.get_attribute("value") : "on"
        elsif native.respond_to?(:value)
          native.value
        end
      end

      def all_text
        text_extractor.all_text(native)
      end

      def visible_text
        text_extractor.visible_text(native)
      end

      def visible?
        driver.visible?(native)
      end

      def checked?
        native.respond_to?(:checked) && native.checked
      end

      def selected?
        native.respond_to?(:selected) && native.selected
      end

      # `disabled` only applies to form-associated elements; on anything else
      # (e.g. a link that incorrectly carries the attribute) it has no effect.
      DISABLEABLE_ELEMENTS = %w[button fieldset input optgroup option select textarea].freeze

      def disabled?
        return false unless DISABLEABLE_ELEMENTS.include?(tag_name)
        return true if native.has_attribute?("disabled")

        if %w[option optgroup].include?(tag_name)
          owner = native.xpath(OPTION_OWNER_XPATH).first
          owner ? self.class.new(driver, owner).disabled? : false
        else
          !native.xpath(DISABLED_BY_FIELDSET_XPATH).empty?
        end
      end

      # readonly does not apply to these input types, so they are never
      # readonly even if the attribute is present (matches RackTest).
      NON_READONLY_TYPES = %w[hidden range color checkbox radio file submit image reset button].freeze

      def readonly?
        return false if input_field? && NON_READONLY_TYPES.include?(field_type)

        native.has_attribute?("readonly")
      end

      def path
        # Capybara's documented placeholder: a shadow tree has no XPath.
        if native.respond_to?(:get_root_node) && native.get_root_node.is_a?(::Dommy::ShadowRoot)
          return "(: Shadow DOM element - no XPath :)"
        end

        native.path
      end

      # Keyboard input without a JS engine: maintains a caret over the field's
      # value and applies printable keys plus the position/modifier keys
      # Capybara's non-JS send_keys specs use. Key *events* are not dispatched
      # (nothing here can observe them without JavaScript).
      def send_keys(*args)
        # Under JavaScript, dispatch real keyboard events (keydown/keypress/
        # input/keyup with browser default actions) through the dommy driver,
        # so keyboard handlers (arrow navigation, Enter selection) run.
        # Key chords ([:shift, "o"]) are not supported on this path.
        return driver.rack_session.send_keys_to(native, *args) if driver.javascript?

        return unless native.respond_to?(:value=)

        state = {chars: native.value.to_s.chars, caret: native.value.to_s.length, shift: false}
        args.each do |arg|
          if arg.is_a?(Array)
            # A chord like [:shift, 'o'] holds its modifiers only for the
            # duration of the array.
            held = state[:shift]
            arg.each { |key| apply_key(state, key) }
            state[:shift] = held
          else
            apply_key(state, arg)
          end
        end
        native.focus if native.respond_to?(:focus)
        native.value = state[:chars].join
      end

      # Computed styles for Capybara's matches_style? / style: filters,
      # served by Dommy's CSS cascade (values come back in the computed
      # serialization, e.g. colors as rgb()).
      def style(styles)
        computed = ::Dommy::Internal::CSS::Cascade.computed_style(native)
        Array(styles).flatten.to_h { |name| [name.to_s, computed[name.to_s].to_s] }
      end

      # --- Interaction ---

      def click(_keys = [], **_options)
        return js_click if driver.javascript?

        if link?
          click_link_node
        elsif submits?
          submit_owning_form
        elsif checkable?
          set(!checked?)
        elsif tag_name == "label"
          click_label
        elsif (details = native.closest("details"))
          toggle_details(details)
        end
      end

      def set(value, **_options)
        return if disabled? || readonly?

        if radio?
          set_radio
        elsif checkbox?
          set_checkbox(value)
        elsif range?
          set_range(value)
        elsif file?
          set_file(value)
        elsif input_field? || textarea?
          set_text_value(value)
        end
      end

      def select_option
        return if disabled?

        select_el = select_node
        deselect_all(select_el) unless select_el&.multiple
        native.selected = true
        notify_select_changed(select_el)
      end

      def unselect_option
        unless select_node&.multiple
          raise Capybara::UnselectNotAllowed, "Cannot unselect option from a non-multiple select box"
        end

        native.selected = false
      end

      # Move the (virtual) pointer over this element: :hover rules and
      # `matches(":hover")` then apply to it and its ancestors. No
      # mouseover/mouseout events are dispatched (nothing observes them
      # without JavaScript).
      def hover
        native.owner_document.__internal_set_hovered_element__(native)
        nil
      end

      # --- Scoped queries (for `within`) ---

      def find_css(locator, **_options)
        native.query_selector_all(locator).map { |element| self.class.new(driver, element) }
      end

      def find_xpath(locator, **_options)
        native.xpath(locator).map { |element| self.class.new(driver, element) }
      end

      # Guard every public method with a staleness check so Capybara can
      # reload a node whose element left the current document (after
      # navigation). Mirrors Capybara::RackTest::Node.
      public_instance_methods(false).each do |meth_name|
        alias_method "unchecked_#{meth_name}", meth_name
        private "unchecked_#{meth_name}"

        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{meth_name}(...)
            stale_check
            send(:"unchecked_#{meth_name}", ...)
          end
        RUBY
      end

      # Identity matters to Capybara (e.g. the focused: filter compares a
      # candidate against session.active_element). Dommy's wrapper cache hands
      # out one wrapper per DOM node, so native equality is node identity.
      def ==(other)
        other.is_a?(Node) && native == other.native
      end

      private

      def apply_key(state, key)
        case key
        when String
          key.each_char do |ch|
            state[:chars].insert(state[:caret], state[:shift] ? ch.upcase : ch)
            state[:caret] += 1
          end
        when :space
          state[:chars].insert(state[:caret], " ")
          state[:caret] += 1
        when :left
          state[:caret] = [state[:caret] - 1, 0].max
        when :right
          state[:caret] = [state[:caret] + 1, state[:chars].length].min
        when :shift
          state[:shift] = true
        end
      end

      def stale_check
        return if native.document.equal?(driver.document)

        raise StaleElementReferenceError, "element is no longer attached to the document"
      end

      def submit_owning_form
        form = form_for(native)
        driver.submit_form(form, submitter: native) if form
      end

      # javascript: links are no-ops in Capybara (a policy decision); every
      # other link delegates to dommy-rack, which handles fragment / same-page
      # / blank-href semantics and raises on genuinely unsupported schemes.
      # A JavaScript click: dispatch the full pointer/mouse/click sequence
      # (Stimulus actions, Turbo's link/submit interception run like in a
      # browser), then perform the un-prevented default action ourselves —
      # link navigation, or the form submission algorithm (a cancelable
      # submit event, then the real submission if nothing canceled it;
      # Turbo cancels and takes over). Checkbox/radio toggling already ran
      # as the click event's activation behavior.
      def js_click
        prevented = ::Dommy::Interaction::EventSynthesis.click(native)
        unless prevented
          # Link navigation and form submission are the elements' own activation
          # behavior — run inside EventSynthesis.click above, routing through the
          # session's navigation delegate (performed when driver.drain_js drains).
          # Only the non-navigating default actions remain here.
          if tag_name == "label"
            click_label
          elsif (details = native.closest("details"))
            toggle_details(details)
          end
        end
        driver.drain_js
        nil
      end

      # Selecting an option through the UI fires input + change on the select
      # (under JavaScript; nothing listens without it).
      def notify_select_changed(select_el)
        return unless driver.javascript? && select_el

        ::Dommy::Interaction::EventSynthesis.input(select_el)
        ::Dommy::Interaction::EventSynthesis.change(select_el)
        driver.drain_js
      end

      def click_link_node
        scheme = native.get_attribute("href").to_s.split(":", 2).first.to_s.downcase
        return if scheme == "javascript"

        driver.follow_link(native)
      end

      def text_extractor
        TextExtractor.new(driver)
      end

      def toggle_details(details)
        if details.has_attribute?("open")
          details.remove_attribute("open")
        else
          details.set_attribute("open", "open")
        end
      end

      def click_label
        control = labelled_control
        return unless control

        node = self.class.new(driver, control)
        node.set(!node.checked?) if node.send(:checkable?)
      end

      def labelled_control
        for_id = native.get_attribute("for")
        if for_id && !for_id.empty?
          document.get_element_by_id(for_id)
        else
          native.query_selector("input, textarea, select")
        end
      end

      def set_text_value(value)
        string = value.to_s
        if text_or_password? && attribute_present?("maxlength")
          string = string[0, native.get_attribute("maxlength").to_i].to_s
        end

        # An <input> value ending in a newline submits a single-field form.
        # There is no submitter button in this case.
        form = single_field_form
        if input_field? && string.end_with?("\n") && form
          write_text(string.chomp)
          driver.submit_form(form, submitter: nil)
        else
          write_text(string)
        end
      end

      # Set a text field's value. Under JavaScript this types like a user:
      # focus, value, then input + change events, so Stimulus/React handlers
      # observe the edit; the JS-less driver keeps the bare value write
      # (nothing listens).
      def write_text(string)
        unless driver.javascript?
          native.value = string
          return
        end

        ::Dommy::Interaction::EventSynthesis.focus(native)
        native.value = string
        ::Dommy::Interaction::EventSynthesis.input(native, string)
        ::Dommy::Interaction::EventSynthesis.change(native)
        driver.drain_js
      end

      def single_field_form
        form = form_for(native)
        return nil unless form && form.query_selector_all("input, textarea").length == 1

        form
      end

      def set_range(value)
        min = (native.get_attribute("min") || 0).to_f
        max = (native.get_attribute("max") || 100).to_f
        step = (native.get_attribute("step") || 1).to_f
        v = value.to_f.clamp(min, max)
        v = (((v - min) / step).round * step) + min
        v = v.clamp(min, max)
        native.value = (v == v.to_i ? v.to_i : v).to_s
      end

      def attribute_present?(name)
        value = native.get_attribute(name)
        value && !value.empty?
      end

      # Toggle through the control's native activation behavior (which fires
      # input/change and, for a radio, maintains its group) — only when it
      # isn't already in the requested state, matching a real click.
      def set_checkbox(value)
        native.click if checked? != !!value
      end

      def set_radio
        native.click unless checked?
      end

      def set_file(value)
        files = Array(value).map do |path|
          path = path.to_s
          raise Capybara::FileNotFound, "cannot attach file, #{path} does not exist" unless ::File.exist?(path)

          ::Dommy::File.new(
            [::File.binread(path)], ::File.basename(path),
            "type" => ::Dommy::Rack::FileUpload.mime_type_for(path)
          )
        end
        native.__driver_set_files__(files)
      end

      def deselect_all(select_el)
        return unless select_el

        select_el.options.each { |option| option.selected = false }
      end

      def form_for(element)
        form_id = element.get_attribute("form")
        if form_id && !form_id.empty?
          document.get_element_by_id(form_id)
        else
          element.closest("form")
        end
      end

      def select_node
        native.closest("select")
      end

      def document
        driver.document
      end

      def field_type
        native.respond_to?(:type) ? native.type : nil
      end

      def input_field? = tag_name == "input"
      def textarea? = tag_name == "textarea"
      def select? = tag_name == "select"
      def radio? = input_field? && field_type == "radio"
      def checkbox? = input_field? && field_type == "checkbox"
      def range? = input_field? && field_type == "range"
      def file? = input_field? && field_type == "file"
      def text_or_password? = input_field? && %w[text password].include?(field_type)
      def checkable? = radio? || checkbox?
      def link? = tag_name == "a" && !native.get_attribute("href").nil?

      def submits?
        if input_field?
          %w[submit image].include?(field_type)
        elsif tag_name == "button"
          field_type == "submit"
        else
          false
        end
      end
    end
  end
end
