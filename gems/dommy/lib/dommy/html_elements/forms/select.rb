# frozen_string_literal: true

module Dommy
  # The `<select>` element and the option list it owns.
  #
  # One of the form-control groups; html_elements/forms.rb lists them.
  # `<select>` — exposes `value` (selected option's value), `options`,
  # `selectedIndex`, and dispatches change events. Minimal compared to
  # happy-dom's full HTMLSelectElement, but covers common test cases.
  class HTMLSelectElement < HTMLElement
    reflect_string :name
    reflect_boolean :multiple
    reflect_ulong size: { default: 0 }
    # Own __js_call__ methods, on top of Element's.


    # HTML "display size": the `size` attribute when positive, else 4 for a
    # multiple select and 1 otherwise. Only at display size 1 does a list with
    # nothing selected fall back to its first option.
    def display_size
      n = size
      n.positive? ? n : (multiple ? 4 : 1)
    end

    # Attributes that decide which selectedness rules the list lives under.
    SELECTEDNESS_ATTRIBUTES = %w[multiple size].freeze

    # HTML's attribute change steps for a select: losing `multiple`, or a change
    # of `size`, changes which rules apply to the list, so settle it again.
    def __internal_attribute_changed__(name, _old_value, _new_value, namespace)
      return nil unless namespace.nil? && SELECTEDNESS_ATTRIBUTES.any? { |a| name.casecmp?(a) }

      __internal_settle_selectedness__
      nil
    end

    # `options` — all <option> descendants (including those inside
    # <optgroup>). Live HTMLOptionsCollection (HTMLCollection +
    # add/remove/selectedIndex/length= helpers).
    def options
      el = self
      HTMLOptionsCollection.new(self) do
        el.__dommy_backend_node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # `selectedOptions` — live collection of the options whose selectedness is
    # true (a settled single-select has at most one).
    def selected_options
      el = self
      @selected_options ||= HTMLCollection.new { el.__display_selected__ }
    end

    def length
      options.size
    end

    # `select.length = n` resizes the options list (delegates to the collection):
    # shrinks by removing trailing options, grows by appending blank ones.
    def length=(n)
      options.length = n
    end

    # `select.namedItem(name)` — the first option whose id or name matches.
    def named_item(name)
      options.named_item(name)
    end

    def form
      closest("form")
    end

    # The options whose selectedness is true. The list is kept consistent as
    # it changes (see #__internal_settle_selectedness__), so nothing is derived
    # here; a list the parser built is settled once, lazily, in case it was
    # never handed the parsed-document steps.
    def __display_selected__
      __internal_settle_selectedness_once__
      options.to_a.select { |o| o.respond_to?(:selected) && o.selected }
    end

    def selected_index
      opts = options.to_a
      sel = __display_selected__.first
      return -1 unless sel

      opts.find_index { |o| o.__dommy_backend_node__.equal?(sel.__dommy_backend_node__) } || -1
    end

    # `selectedIndex=`: every option's selectedness becomes false, then the one
    # at `i` (if any) becomes true and dirty — bare writes, no reset: an
    # out-of-range index leaves nothing selected, as in a browser.
    def selected_index=(i)
      target = i.to_i
      options.to_a.each_with_index do |o, idx|
        chosen = idx == target
        o.__internal_write_selectedness__(chosen, dirty: chosen)
      end
      nil
    end

    # HTML reset algorithm: reset every option's selectedness, then run the
    # selectedness setting algorithm — a single-selection select whose options
    # all lost their `selected` attribute falls back to its first option.
    def __internal_reset__
      options.to_a.each(&:__internal_reset__)
      __internal_settle_selectedness__
    end

    # HTML: in a select without `multiple`, "whenever an option element in the
    # select element's list of options has its selectedness set to true, set
    # the selectedness of all the other option elements to false".
    def __internal_deselect_others__(keep)
      keep_node = keep.__dommy_backend_node__
      options.to_a.each do |o|
        next if o.__dommy_backend_node__.equal?(keep_node)
        next unless o.respond_to?(:selected) && o.selected

        o.__internal_write_selectedness__(false)
      end
      nil
    end

    # The list of options gained or lost members. `arrived` is the options that
    # landed in it, in tree order (an arriving optgroup having already been
    # expanded into the options it carried). HTML: an option added to the list
    # with its selectedness already true sets every other option's to false — so
    # of several arriving selected, the last in tree order wins, wherever in the
    # list they landed — and then the list settles.
    def __internal_options_changed__(arrived)
      unless multiple
        winner = arrived.reverse_each.find { |option| option.respond_to?(:selected) && option.selected }
        __internal_deselect_others__(winner) if winner
      end
      __internal_settle_selectedness__
    end

    # A list that was never settled — the parser built it, in a document or a
    # fragment, and no mutation has touched it since — is settled now. A select
    # whose list was already settled is left alone: moving or inserting the
    # select itself changes nothing in its list of options, so an explicit
    # "nothing selected" (selectedIndex = -1) survives the move.
    def __internal_settle_selectedness_once__
      __internal_settle_selectedness__ unless @selectedness_settled
      nil
    end

    # The selectedness setting algorithm (HTML §4.10.7). Runs when the list of
    # options gains or loses members, when an option asks for a reset, on the
    # select's own reset, and when `multiple` / `size` change. Only for a select
    # without `multiple`: a list with nothing selected selects its first
    # non-disabled option (at display size 1 only); a list with several selected
    # keeps only the last of them in tree order.
    def __internal_settle_selectedness__
      @selectedness_settled = true
      return nil if multiple

      opts = options.to_a
      chosen = opts.select { |o| o.respond_to?(:selected) && o.selected }
      if chosen.empty?
        first = opts.find { |o| selectable?(o) } if display_size == 1
        first&.__internal_write_selectedness__(true)
      elsif chosen.length > 1
        chosen[0...-1].each { |o| o.__internal_write_selectedness__(false) }
      end
      nil
    end

    # `value` of the select = value of the (displayed) selected option, or "".
    def value
      sel = __display_selected__.first
      sel ? sel.value.to_s : ""
    end

    # `value=`: every option's selectedness becomes false, then the first whose
    # value matches (if any) becomes true and dirty — bare writes, no reset: a
    # value no option has leaves nothing selected, as in a browser.
    def value=(new_value)
      opts = options.to_a
      target = opts.find { |o| o.value.to_s == new_value.to_s }
      opts.each { |o| o.__internal_write_selectedness__(false) }
      target&.__internal_write_selectedness__(true, dirty: true)
      nil
    end

    # An option this select may settle on: one that is not disabled, itself or
    # through its optgroup. The option answers that; the select only asks.
    def selectable?(option)
      option.respond_to?(:__internal_disabled_for_selection__) &&
        !option.__internal_disabled_for_selection__
    end
    private :selectable?

    # `select.item(i)` — returns the option at index i.
    def item(i)
      options[i.to_i]
    end

    # `select.add(option, before)` — appends or inserts before `before`.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__dommy_backend_node__)

      if before.respond_to?(:__dommy_backend_node__)
        insert_before(option, before)
      else
        append_child(option)
      end

      nil
    end

    # `select.remove(i)` — removes the option at index i. (Note: also
    # inherits `remove()` from ChildNode for self-removal; spec lets
    # both forms coexist via overloading.)
    def remove_option(i)
      idx = i.to_i
      # An index out of range (including a negative one) is a no-op — NOT Ruby's
      # from-the-end negative indexing.
      return if idx.negative? || idx >= options.length

      options[idx]&.remove
    end

    def labels
      labels_node_list
    end

    def type
      multiple ? "select-multiple" : "select-one"
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled") && !disabled_by_ancestor_fieldset? && closest("datalist").nil?
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please select an item in the list." if validity.value_missing

      ""
    end

    def check_validity
      ok = !will_validate || validity.valid
      dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true)) unless ok
      ok
    end

    def report_validity
      check_validity
    end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    js_accessor :value, selected_index: "selectedIndex", length: "length"
    js_readable :options, :size, :form, :labels, :type, :validity,
      selected_options: "selectedOptions",
      will_validate: "willValidate", validation_message: "validationMessage"

    # Indexed getter: `select[i]` is the option at index i (WebIDL).
    def __js_get__(key)
      return item(key) if key.is_a?(Integer)
      return item(key.to_i) if key.is_a?(String) && key.match?(/\A\d+\z/)

      super
    end

    # Indexed setter: `select[i] = option` delegates to the options collection's
    # WebIDL "set an indexed property" algorithm.
    def __js_set__(key, val)
      if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A\d+\z/))
        return options.__set_indexed__(key.to_i, val)
      end

      super
    end

    js_methods %w[item namedItem add remove checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "namedItem"
        named_item(args[0])
      when "add"
        add(args[0], args[1])
      when "remove"
        # HTMLSelectElement.remove(index) removes an option; with no argument it
        # is ChildNode.remove() (removes the <select> itself).
        args.empty? ? super : remove_option(args[0])
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      when "setCustomValidity"
        set_custom_validity(args[0])
      else
        super
      end
    end

  end

  # `<dialog>` — `open` reflected boolean, `show()` / `showModal()` /
  # `close(returnValue?)`. Dommy has no modal stack, so showModal is
  # functionally identical to show (no backdrop, no escape-to-close).

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.

  # `<option>` — value, label, selected, disabled, text, index, form.
  class HTMLOptionElement < HTMLElement
    reflect_boolean :disabled
    def value
      # `value`/`label` reflect the NO-namespace content attribute (a same-named
      # attribute in another namespace, via setAttributeNS, does not count);
      # both default to the option's `text` when their attribute is absent.
      has_attribute_ns?(nil, "value") ? get_attribute_ns(nil, "value").to_s : text
    end

    def value=(v)
      set_reflected_string("value", v)
    end

    def label
      has_attribute_ns?(nil, "label") ? get_attribute_ns(nil, "label").to_s : text
    end

    def label=(v)
      set_reflected_string("label", v)
    end

    # `defaultSelected` reflects the `selected` content attribute.
    def default_selected
      reflected_boolean("selected")
    end

    def default_selected=(v)
      set_reflected_boolean("selected", v)
    end

    # `selected` is the selectedness state. It is a distinct boolean (the IDL
    # getter returns it directly), initialised from defaultSelected. While the
    # dirtiness flag is false, adding/removing the `selected` content attribute
    # re-syncs selectedness to it; the IDL setter makes it dirty so it then holds
    # its value independently of the attribute.
    def selected
      @selectedness = default_selected if @selectedness.nil?
      @selectedness
    end

    # IDL setter: set selectedness, mark it dirty, then ask the owning select
    # for a reset (its selectedness setting algorithm).
    def selected=(value)
      @selectedness_dirty = true
      __internal_set_selectedness__(value)
      ask_for_reset
    end

    # Set selectedness without touching dirtiness (the Option constructor's
    # step, the `selected` attribute while not dirty). HTML: in a select
    # without `multiple`, an option whose selectedness becomes true sets every
    # other option's to false — right away, before any reset runs, so the
    # option just set is the one that survives.
    def __internal_set_selectedness__(value)
      __internal_write_selectedness__(value)
      owner = __internal_owner_select__
      owner.__internal_deselect_others__(self) if @selectedness && owner && !owner.multiple
      nil
    end

    # The bare write, with no cross-option rule: the owning select's bulk
    # setters (value=, selectedIndex=) and its selectedness setting algorithm
    # keep the list consistent themselves. `dirty:` is for those setters' one
    # chosen option — HTML has them set its dirtiness too, so the `selected`
    # attribute stops driving it from then on.
    def __internal_write_selectedness__(value, dirty: false)
      @selectedness = !!value
      @selectedness_dirty = true if dirty
      note_selectedness_change
    end

    # HTML reset algorithm (run for each option by the owning select, which then
    # settles the list): clear the dirtiness flag and re-sync selectedness to
    # the `selected` content attribute.
    def __internal_reset__
      @selectedness_dirty = false
      __internal_write_selectedness__(default_selected)
    end

    # The select whose list of options this option is in — nil while detached.
    # Matches HTMLSelectElement#options, which collects every descendant option.
    def __internal_owner_select__
      owner = closest("select")
      owner.is_a?(HTMLSelectElement) ? owner : nil
    end

    # HTML's attribute change steps for an option: while not dirty, selectedness
    # follows the `selected` content attribute.
    def __internal_attribute_changed__(name, _old_value, _new_value, namespace)
      return nil unless namespace.nil? && name.casecmp?("selected")

      sync_selectedness_from_attribute
      nil
    end

    # The `selected` content attribute came or went: while not dirty,
    # selectedness follows it. HTML's attribute steps stop there; browsers then
    # also reset the list (removing the attribute from the only selected option
    # of a single-select re-selects the first option), so ask for one.
    def sync_selectedness_from_attribute
      return if @selectedness_dirty

      __internal_set_selectedness__(default_selected)
      ask_for_reset
    end

    def text
      # WHATWG: strip-and-collapse ASCII whitespace over the concatenated Text
      # node descendants — excluding any inside a script (HTML or SVG) element.
      parts = []
      collect_option_text(@__node__, parts)
      parts.join.gsub(/[\t\n\f\r ]+/, " ").strip
    end

    def text=(v)
      self.text_content = v
    end

    # HTML's "disabled" concept for an option: the attribute on the option
    # itself, or on the optgroup it sits in. Asked by the owning select when it
    # looks for the first option it may select.
    def __internal_disabled_for_selection__
      return true if disabled

      parent = parent_element
      parent.is_a?(HTMLOptGroupElement) && parent.disabled
    end

    private

    # Selectedness is property state (no attribute mutation announces it), yet
    # it is selector-observable twice over: as this option's :checked, and as
    # the owning select's value behind :invalid / :valid. Every selectedness
    # writer funnels here — `select.value=` and `selected_index=` included,
    # since they set each option's selectedness — so the caches are invalidated
    # exactly as a checkbox's `checked=` invalidates them.
    def note_selectedness_change
      @document&.__internal_note_selector_state_change__
      nil
    end

    # HTML "ask for a reset": the owning select runs its selectedness setting
    # algorithm over the whole list.
    def ask_for_reset
      __internal_owner_select__&.__internal_settle_selectedness__
      nil
    end

    def collect_option_text(node, parts)
      node.children.each do |child|
        if child.text?
          parts << child.content
        elsif child.element? && !excluded_from_option_text?(child)
          collect_option_text(child, parts)
        end
      end
    end

    # Per spec, option.text skips the descendants of an HTML/SVG `script` and an
    # HTML `style` element — but NOT a same-named element in another namespace
    # (a MathML or null-namespace `<script>` still contributes its text).
    def excluded_from_option_text?(node)
      name = node.name.to_s.downcase
      return false unless %w[script style].include?(name)

      el = @document.wrap_node(node)
      ns = el.respond_to?(:namespace_uri) ? el.namespace_uri : nil
      html = Internal::Namespaces::HTML
      svg = Internal::Namespaces::SVG
      name == "script" ? [html, svg].include?(ns) : ns == html
    end

    public

    def form
      closest("form")
    end

    # `index` — position within the containing select's options list.
    def index
      sel = closest("select")
      return 0 unless sel

      sel.options.find_index { |o| o.__dommy_backend_node__ == @__node__ } || 0
    end

    js_accessor :value, :label, :default_selected, :selected, :text
    js_readable :form, :index

  end

  # `<optgroup>` — label + disabled, container for options.

  # `<optgroup>` — label + disabled, container for options.

  # `<optgroup>` — label + disabled, container for options.
  class HTMLOptGroupElement < HTMLElement
    reflect_string :label
    reflect_boolean :disabled
  end

  # `<textarea>` — multi-line text input.

  # `<textarea>` — multi-line text input.

  class HTMLDataListElement < HTMLElement
    # `options` — the <option> descendants, as a live HTMLCollection.
    def options
      el = self
      HTMLCollection.new do
        el.__dommy_backend_node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def __js_get__(key)
      return options if key == "options"

      super
    end
  end
end
