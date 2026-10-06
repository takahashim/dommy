# frozen_string_literal: true

module Dommy
  # The `<form>` itself, and the controls that are neither `<input>` nor
  # `<select>`.
  #
  # One of the form-control groups; html_elements/forms.rb lists them.
  # The form and its controls: what a user fills in and what a form submits.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<form>` — element collection, submit/reset, and a stubbed
  # validation surface.
  class HTMLFormElement < HTMLElement
    include SubmissionUrlAttribute
    reflect_token_list rel_list: { attr: "rel", js: "relList", supported: Internal::SupportedTokens::HYPERLINK_REL }
    reflect_setter :action
    def action = submission_url("action")
    # `encoding` reflects the same `enctype` attribute as `enctype` does.
    reflect_enumerated method_attr: Internal::EnumeratedKeywordSets::METHOD.merge(attr: "method", js: "method"),
                       enctype: Internal::EnumeratedKeywordSets::ENCTYPE,
                       encoding: Internal::EnumeratedKeywordSets::ENCTYPE.merge(attr: "enctype"),
                       autocomplete: { keywords: %w[on off], missing: "on", invalid: "on" }
    # Own __js_call__ methods, on top of Element's.

    # `form.elements` — listed elements inside the form (excludes
    # nested forms per spec; we approximate by walking
    # input/select/textarea/button/output/fieldset). Returned as a
    # live HTMLCollection so listening to `submit`/`reset` and
    # adding fields between accesses works as expected.
    # `form.elements` — the listed controls owned by this form, in document tree
    # order, excluding input type=image. Membership follows the WHATWG form-owner
    # algorithm (a `form` content attribute overrides DOM nesting), NOT plain
    # descendant containment, so controls associated via `form=id` are included
    # and a control in a nested inner form is excluded. Memoized so the live
    # collection is the [SameObject] each access returns.
    LISTED_CONTROL_SELECTOR = "input, select, textarea, button, output, fieldset, object"

    # Events a form swallows rather than letting them reach its own listeners
    # when they were fired at another node — see the dispatch hook below.
    LEGACY_STOPPED_EVENTS = %w[submit reset].freeze

    # HTML's legacy form dispatch rule: a form does not see a `submit` or `reset`
    # event that was fired at a different node; the event stops here instead,
    # without running this form's listeners. What it is for is nested forms —
    # the parser never produces one, but the DOM API lets you build one, and
    # this is what keeps submitting an inner form from also running the outer
    # form's `onsubmit`. Capture is exempt: dispatch only consults this hook
    # once the event is at or past its target, so the event still reaches it.
    def __internal_legacy_stops_propagation__(event)
      return false unless LEGACY_STOPPED_EVENTS.include?(event.type)

      target = event.__js_get__("target")
      return false if target.nil?
      return false if target.is_a?(Node) && target.__dommy_backend_node__ == @__node__

      true
    end

    def elements
      el = self
      @elements ||= HTMLFormControlsCollection.new do
        # The form's own TREE is the search scope, so a control associated by a
        # `form=` attribute from outside the subtree is still found while one in
        # another tree — a shadow tree, or the light DOM around one — is not.
        scope = el.get_root_node || el
        scope.query_selector_all(LISTED_CONTROL_SELECTOR).select do |c|
          next false if c.tag_name.to_s.casecmp?("input") && c.respond_to?(:type) && c.type.to_s.casecmp?("image")

          el.__internal_owns_control__(c)
        end
      end
    end

    # The form owner of a listed control, per WHATWG: when the control carries a
    # `form` content attribute, its owner is the form element with that id (or
    # nothing, if the id resolves to a non-form / nothing); otherwise it is the
    # nearest ancestor form element.
    def __internal_owns_control__(control)
      owner = control.__internal_form_owner__
      !owner.nil? && owner.__dommy_backend_node__.equal?(__dommy_backend_node__)
    end

    def length
      elements.size
    end

    # HTML's "constructing entry list" flag: set while the form builds its
    # entry list (and fires `formdata`), so a listener cannot re-enter it.
    attr_accessor :__internal_constructing_entry_list__

    # Spec: `submit()` submits the form "from the submit() method" — WITHOUT
    # firing a `submit` event and without constraint validation. Navigation is
    # handed to the delegate (a no-op recording by default).
    def submit
      __internal_submit_form__(self, from_submit_method: true)
      nil
    end

    # HTML "reset a form": fire a cancelable `reset` event, and unless it was
    # prevented, run every resettable control's reset algorithm — which drops the
    # dirty value / checkedness so the control reverts to its content attributes.
    def reset
      reset_event = Event.new("reset", "bubbles" => true, "cancelable" => true).__internal_mark_trusted__
      return false unless dispatch_event(reset_event)

      elements.to_a.each { |control| control.__internal_reset__ if control.respond_to?(:__internal_reset__) }
      true
    end

    # `requestSubmit(submitter)` mirrors a user's submission: a non-null
    # submitter must be a submit button (else TypeError) whose form owner is
    # this form (else NotFoundError); then the form is submitted from it — or
    # from the form itself when there is none. Returns true unless the submit
    # event was canceled (the JS method returns undefined).
    def request_submit(submitter = nil)
      submitter = nil if submitter.equal?(Bridge::UNDEFINED)
      unless submitter.nil?
        unless submitter.is_a?(HTMLElement) && FormEntryList.submit_button?(submitter)
          raise Bridge::TypeError, "The specified element is not a submit button."
        end
        unless __internal_owns_control__(submitter)
          raise DOMException::NotFoundError, "The specified element is not owned by this form element."
        end
      end

      __internal_submit_form__(submitter || self)
    end

    # The interactive submission path, shared by `requestSubmit()`, a submit
    # button's activation (driver click), and Enter's implicit submission.
    def __internal_run_form_submission__(submitter = nil)
      __internal_submit_form__(submitter || self)
    end

    # HTML "submit a form from submitter". Unless submitted from `submit()`:
    # interactively validate the constraints (unless the no-validate state is
    # set) and fire a cancelable, trusted `SubmitEvent` carrying the submitter.
    # Then construct the entry list (firing `formdata`) and either close the
    # form's dialog (method=dialog) or hand the navigation to the delegate.
    # Returns false when the submission stopped before that point.
    def __internal_submit_form__(submitter, from_submit_method: false)
      # "If form cannot navigate, then return" — a form that is not connected
      # has no navigable, so clicking its submit button fires nothing at all.
      return false unless is_connected?
      return false if @__internal_constructing_entry_list__

      unless from_submit_method
        # Reentrancy guard: a submit handler that submits the form again is a
        # no-op.
        return false if @firing_submission_events

        @firing_submission_events = true
        begin
          # "If the submitter element's no-validate state is false, then
          # interactively validate the constraints ... If the result is
          # negative, return" — an invalid form fires `invalid` on each failing
          # control and never fires `submit`.
          return false unless no_validate?(submitter) || report_validity

          submitter_button = submitter.equal?(self) ? nil : submitter
          should_continue = dispatch_event(
            SubmitEvent.new("submit",
              "bubbles" => true, "cancelable" => true, "submitter" => submitter_button).__internal_mark_trusted__
          )
        ensure
          @firing_submission_events = false
        end
        return false unless should_continue
        return false unless is_connected?
      end

      __internal_navigate_for_submit__(submitter.equal?(self) ? nil : submitter)
      true
    end

    # HTML's no-validate state: true when the form carries `novalidate`, or
    # when the clicked control is a submit button carrying `formnovalidate`.
    def no_validate?(submitter)
      return true if __internal_has_attribute__?("novalidate")
      return false if submitter.equal?(self)

      submitter.respond_to?(:__internal_has_attribute__?) && submitter.__internal_has_attribute__?("formnovalidate")
    end

    # The submitter's method state: a submit button's `formmethod` when it has
    # one, else the form's `method` — "get", "post" or "dialog".
    def __internal_submission_method__(submitter)
      raw = if submitter && FormEntryList.submit_button?(submitter) && submitter.__internal_has_attribute__?("formmethod")
              submitter.__internal_attribute_value__("formmethod")
            else
              __internal_attribute_value__("method")
            end
      method = raw.to_s.downcase(:ascii)
      %w[get post dialog].include?(method) ? method : "get"
    end

    # Build the form data set and hand the resulting navigation to the delegate.
    # Reuses the core FormSubmission serializer (submitter, method, action,
    # enctype, GET query-stripping) — method-override is a host concern, so it's
    # left off here (the delegate applies its own policy).
    def __internal_navigate_for_submit__(submitter)
      return submit_dialog(submitter) if __internal_submission_method__(submitter) == "dialog"

      win = @document&.default_view
      return if win.nil?

      result = Dommy::Interaction::FormSubmission.new(self, submitter).submit!
      return if result.nil?
      # HTML re-runs "cannot navigate" after constructing the entry list: the
      # `formdata` event may have removed the form (or its document).
      return unless is_connected?

      win.__internal_navigate__(
        url: result[:url], method: result[:method], params: result[:params],
        enctype: result[:enctype], target: result[:target], source: :form
      )
    end

    # The dialog method: the entry list is still constructed (so `formdata`
    # fires), then — instead of navigating — the form's nearest ancestor
    # `<dialog>` closes with the submitter's result: an Image Button's selected
    # coordinate "x,y", another submit button's optional value (its `value`
    # attribute, else null), or null.
    def submit_dialog(submitter)
      return if FormEntryList.new(self, submitter: submitter).form_data.nil?
      return unless is_connected?

      subject = parent_element
      subject = subject.parent_element until subject.nil? || subject.is_a?(HTMLDialogElement)
      return if subject.nil?

      result =
        if submitter.is_a?(HTMLInputElement) && submitter.type == "image"
          submitter.__internal_selected_coordinate__.join(",")
        elsif submitter && FormEntryList.submit_button?(submitter)
          submitter.__internal_attribute_value__("value")
        end
      subject.close(result)
      nil
    end
    private :submit_dialog

    # HTML "statically validate the constraints": every submittable element
    # this form owns (image buttons included) that is a candidate for
    # constraint validation and fails its constraints gets a trusted,
    # cancelable `invalid` event; the form is valid when there is none.
    def check_validity
      invalid = __internal_submittable_controls__.select do |control|
        control.will_validate && !control.__internal_satisfies_constraints__?
      end
      invalid.each(&:__internal_fire_invalid__)
      invalid.empty?
    end

    # "Interactively validate the constraints": the same, with no user to
    # report the problems to.
    def report_validity
      check_validity
    end

    # The submittable elements whose form owner is this form, in tree order.
    def __internal_submittable_controls__
      scope = get_root_node || self
      scope.query_selector_all(FormEntryList::SUBMITTABLE_SELECTOR).to_a.select { |c| __internal_owns_control__(c) }
    end

    def __js_get__(key)
      if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A(?:0|[1-9]\d*)\z/))
        return elements.to_a[key.to_i] || Bridge::ABSENT
      end

      # HTMLFormElement is [LegacyOverrideBuiltIns]: a control whose name/id
      # matches a builtin (`elements`, `length`, `submit`, `action`, …) shadows
      # that builtin. So the named getter is consulted BEFORE the builtins.
      name = key.to_s
      named = named_controls[name]
      if named && !named.empty?
        remember_past_name(name, named.first) if named.length == 1
        return __internal_named_getter_result__(name, named)
      end
      past = past_named_control(name)
      return past if past

      case key
      when "elements"
        elements
      when "length"
        length
      else
        super
      end
    end

    # HTML's "past names map": the named getter remembers the single control it
    # last returned under a name, so a control that is later renamed — or loses
    # its name and id entirely — stays reachable under the old one. The entry
    # lives only as long as the control still belongs to this form; removing it
    # from the form, or pointing it at another one, drops the name.
    def remember_past_name(name, element)
      (@__past_names__ ||= {})[name] = element
      nil
    end

    def past_named_control(name)
      entry = @__past_names__&.[](name)
      return nil if entry.nil?
      return entry if own_control?(entry)

      @__past_names__.delete(name)
      nil
    end

    def own_control?(element)
      node = element.__dommy_backend_node__ if element.is_a?(Node)
      return false unless node

      elements.any? { |el| el.__dommy_backend_node__.equal?(node) }
    end

    # A single matching control is returned directly; multiple matches yield a
    # RadioNodeList. The list is memoized per name and refreshed in place so
    # repeated named-getter reads return the [SameObject] (WebIDL requires
    # `form.d === form.d`), while still reflecting live membership.
    def __internal_named_getter_result__(name, matches)
      return matches.first if matches.length == 1

      form = self
      (@__radio_lists ||= {})[name] ||= RadioNodeList.new { form.named_controls[name] || [] }
    end

    # WebIDL named getter: the form's supported property names are the name/id
    # of each of its listed controls, followed by the names in its past names
    # map that still point at one of them.
    def __js_named_props__
      live = named_controls.keys
      past = (@__past_names__ || {}).keys.select { |name| past_named_control(name) }
      live + (past - live)
    end

    # name/id -> [controls], for the named getter (a name matching more than one
    # control yields a RadioNodeList-like NodeList).
    def named_controls
      map = ::Hash.new { |h, k| h[k] = [] }
      elements.each do |el|
        node = el.__dommy_backend_node__
        name = Backend.no_namespace_attribute_value(node, "name").to_s
        map[name] << el unless name.empty?
        id = Backend.no_namespace_attribute_value(node, "id").to_s
        map[id] << el unless id.empty? || id == name
      end
      map
    end

    js_methods %w[submit reset requestSubmit checkValidity reportValidity]
    def __js_call__(method, args)
      case method
      when "submit"
        submit
      when "reset"
        reset
      when "requestSubmit"
        request_submit(args[0])
        nil
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      else
        super
      end
    end
  end

  # `<input>` — covers the most-used form control surface.

  # `<input>` — covers the most-used form control surface.

  # `<button>`: a submit button by default, a plain button when it has a
  # `command` or `commandfor` (HTML's Auto state), and an invoker — of the
  # element its `commandfor` names, through a CommandEvent and the built-in
  # popover and dialog commands, or of its `popovertarget` popover.
  class HTMLButtonElement < HTMLElement
    include SubmitButtonActivation
    include Internal::PopoverInvokerElement
    include Internal::ConstraintValidation
    reflect_setter :type, :command
    reflect_enumerated form_enctype: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_ENCTYPE.merge(attr: "formenctype"),
                       form_method: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_METHOD.merge(attr: "formmethod")
    include SubmissionUrlAttribute
    reflect_setter form_action: "formaction"
    def form_action = submission_url("formaction")

    # The `command` keywords other than a custom one ("--" and anything).
    COMMAND_KEYWORDS = %w[toggle-popover show-popover hide-popover close request-close show-modal].freeze
    POPOVER_COMMANDS = %w[toggle-popover show-popover hide-popover].freeze

    # The type attribute's state: "submit", "reset", "button", or "auto"
    # for a missing or invalid value.
    def type_state
      raw = __internal_attribute_value__("type")&.downcase(:ascii)
      %w[submit reset button].include?(raw) ? raw : "auto"
    end

    # HTML "submit button": the Submit Button state, or the Auto state with
    # neither command nor commandfor, outside a select.
    def __internal_submit_button_state__?
      state = type_state
      return true if state == "submit"

      state == "auto" && !__internal_has_attribute__?("command") && !__internal_has_attribute__?("commandfor") &&
        !parent_node.is_a?(HTMLSelectElement)
    end

    # `type`: "submit" for a submit button, "button" for the Auto state that
    # is not one, else the keyword.
    def type
      return "submit" if __internal_submit_button_state__?

      state = type_state
      state == "auto" ? "button" : state
    end

    def __internal_submit_button__? = __internal_submit_button_state__? && !disabled

    def __internal_popover_invoker_button__? = true

    # `command`: the command attribute's keyword (lowercased) or custom
    # command ("--" and anything, as written); "" in the Unknown state.
    def command
      raw = __internal_attribute_value__("command")
      return "" if raw.nil?
      return raw if raw.start_with?("--")

      keyword = raw.downcase(:ascii)
      COMMAND_KEYWORDS.include?(keyword) ? keyword : ""
    end

    # A button always has activation behavior.
    def activation_target? = true

    # HTML's button activation behavior: a disabled button does nothing; one
    # with a form owner submits it (a submit button), resets it (a reset
    # button) or, in the Auto state, does nothing more; otherwise the button
    # invokes its commandfor target, or else its popovertarget popover.
    def activation_behavior(event)
      return if __internal_actually_disabled__

      if form
        return super if __internal_submit_button__?
        return form.reset if type_state == "reset"
        return if type_state == "auto"
      end

      target = command_for_element
      if target
        run_command(target)
      else
        run_popover_target_activation(event.__js_get__("target"))
      end
    end

    # The form owner: a `form=` attribute pointing at a form (form-associated
    # element, so a button can live outside its form), else the nearest ancestor
    # form.
    def form
      __internal_form_owner__
    end

    def labels
      labels_node_list
    end

    # Only a submit button is a candidate for constraint validation; reset /
    # button types are barred, besides the shared reasons.
    def __internal_barred_from_constraint_validation__?
      super || type != "submit"
    end

    def __js_get__(key)
      case key
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        set_reflected_string("type", value)
      else
        super
      end
    end
    private

    # The command and commandfor half of the activation behavior: fire a
    # cancelable CommandEvent at the target, then run the built-in command —
    # the popover commands on any HTML element, the dialog ones through the
    # dialog's command steps. A custom command only fires the event.
    def run_command(target)
      command = self.command
      return unless command_valid_for?(command, target)

      event = CommandEvent.new("command", "command" => command, "source" => self, "cancelable" => true)
      return unless target.dispatch_event(event.__internal_mark_trusted__)
      return unless target.is_connected?
      return if command.start_with?("--")

      if POPOVER_COMMANDS.include?(command)
        run_popover_command(target, command)
      elsif target.respond_to?(:__internal_run_command__)
        target.__internal_run_command__(self, command)
      end
    end

    # HTML "determine if a command is valid for a target".
    def command_valid_for?(command, target)
      return false if command.empty?
      return true if command.start_with?("--")
      return false unless target.is_a?(HTMLElement)
      return true if POPOVER_COMMANDS.include?(command)

      target.respond_to?(:__internal_valid_command__?) && target.__internal_valid_command__?(command)
    end

    def run_popover_command(target, command)
      showing = target.__internal_popover_valid__?(true)
      if command == "hide-popover" || (command == "toggle-popover" && !target.__internal_popover_valid__?(false))
        target.__internal_hide_popover__(true, true, false, source: self) if showing
      elsif target.__internal_popover_valid__?(false)
        target.__internal_show_popover__(false, self)
      end
    end
  end

  # `<img>` — reflected URL/dimension attributes. Dommy has no real
  # image loading, so `complete`/`naturalWidth`/`naturalHeight` are
  # static (complete=true, dimensions=0).

  # `<option>` — value, label, selected, disabled, text, index, form.

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
    include Internal::TextSelection
    include Internal::ConstraintValidation
    # The plain reflections — `rows` / `cols` ([ReflectPositiveWithFallback],
    # defaults 2 and 20), `maxLength` / `minLength` ([ReflectNonNegative]) —
    # come from the IDL (Internal::IdlReflection).

    # `autocomplete` — the setter reflects, but the getter is HTML's autofill
    # processing model (Internal::Autofill). A textarea has no type state, so
    # it always wears the "autofill expectation mantle".
    reflect_setter :autocomplete
    def autocomplete
      Internal::Autofill.idl_exposed_value(__internal_attribute_value__("autocomplete"))
    end
    # Own __js_call__ methods, on top of Element's.

    # The raw value is the dirty value once set (a wrapper-level flag, NOT a
    # content attribute, so `setAttribute("value", …)` can't touch it),
    # otherwise the child text content — HTML's children changed steps keep a
    # pristine raw value in step with it.
    def raw_value
      @__value_dirty ? @__value.to_s : default_value
    end

    # The API value (`value`, `textLength`, maxlength, the selection APIs): the
    # raw value with newlines normalized — CRLF and CR become LF.
    def value
      raw_value.gsub(/\r\n?/, "\n")
    end

    # HTML: the raw value becomes the new value and the dirty value flag is
    # set; an API value that changed moves the text entry cursor to the end.
    def value=(v)
      old_value = value
      @__value = v.to_s
      @__value_dirty = true
      @__last_changed_by_user_edit = false
      __internal_move_cursor_to_end__ if value != old_value
      @document&.__internal_note_value_change__
    end

    # A user's edit (a driver typing): tooLong / tooShort apply to it.
    def __internal_user_edit_value__(raw)
      self.value = raw
      @__last_changed_by_user_edit = true
    end

    def __internal_last_changed_by_user_edit__ = @__last_changed_by_user_edit && @__value_dirty ? true : false

    # HTML's children changed steps: a pristine raw value is the child text
    # content again, so a selection past its new end is pulled back to it.
    # A replacement (textContent=, defaultValue=) removes the old children
    # before inserting the new ones, and the steps run in between too.
    def __internal_children_changed__(added_nodes, removed_nodes)
      return if @__value_dirty

      unless removed_nodes.empty? || added_nodes.empty?
        remaining = @__node__.children.reject { |child| added_nodes.any? { |node| node.equal?(child) } }
        text = remaining.select { |child| child.text? || child.cdata? }.map(&:content).join
        clamp_selection_to(Internal::Utf16.length(text.gsub(/\r\n?/, "\n")))
      end
      sync_selection
    end

    # setRangeText's edit of the relevant value: it sets the dirty value flag.
    def __internal_set_relevant_value__(string)
      @__value = string
      @__value_dirty = true
      @document&.__internal_note_value_change__
    end

    # The element's value, as form submission sees it: the API value with the
    # textarea wrapping transformation applied — in the Hard wrap state, line
    # feeds are inserted so that no line is longer than `cols` characters.
    def __internal_submission_value__
      text = value
      return text unless __internal_attribute_value__("wrap").to_s.casecmp?("hard")

      width = cols
      text.split("\n", -1).map { |line| line.scan(/.{1,#{width}}/m).then { |parts| parts.empty? ? [""] : parts }.join("\n") }.join("\n")
    end

    # HTML reset algorithm: clear the dirty value flag so `value` reverts to the
    # child text content.
    def __internal_reset__
      @__value = nil
      @__value_dirty = false
      @__last_changed_by_user_edit = false
      @document&.__internal_note_value_change__
      nil
    end

    # defaultValue is the child text content (the element's own Text
    # children, not deeper descendants'); setting it leaves the dirty value
    # flag alone.
    def default_value
      Backend.child_text_content(@__node__)
    end

    def default_value=(v)
      self.text_content = v
    end

    # HTML cloning steps: copy the dirty value flag + raw value so a clone keeps
    # the user-entered text rather than reverting to the default (child text).
    def __internal_cloning_state__
      merge_cloning_state(super, @__value_dirty ? {value: @__value, dirty: true} : {})
    end

    def __internal_apply_cloning_state__(state)
      super
      return unless state[:dirty]

      @__value = state[:value]
      @__value_dirty = true
    end

    private

    public

    # The length of the API value, in UTF-16 code units.
    def text_length
      Internal::Utf16.length(value)
    end

    def type
      "textarea"
    end

    def form
      __internal_form_owner__
    end

    def labels
      labels_node_list
    end




    # A readonly textarea is barred from constraint validation.
    def __internal_barred_from_constraint_validation__?
      super || __internal_has_attribute__?("readonly")
    end

    js_accessor :value, :default_value, :selection_start, :selection_end, :selection_direction
    js_readable :text_length, :type, :form, :labels

    js_methods %w[select setSelectionRange setRangeText]
    def __js_call__(method, args)
      case method
      when "select"
        select
      when "setSelectionRange"
        set_selection_range(args[0], args[1], args[2])
      when "setRangeText"
        __internal_js_set_range_text__(args)
      else
        super
      end
    end
    # end HTMLTextAreaElement
  end

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.
  class HTMLLabelElement < HTMLElement

    # HTML "interactive content" (§3.2.5.2.7): a click that landed on one of
    # these inside a label is NOT forwarded again by the label — the element
    # handles its own click. An input is interactive unless hidden; a, audio,
    # img and video only with the attribute that makes them so.
    INTERACTIVE_CONTENT = "a[href], audio[controls], button, details, embed, iframe, img[usemap], " \
                          "input:not([type=hidden i]), label, select, textarea, video[controls]"

    def activation_target?
      !control.nil?
    end

    # HTML: a label's activation behavior runs synthetic click activation steps
    # on its labeled control — which is what makes clicking a label's text check
    # the checkbox next to it. Browsers also move focus to the control first (a
    # label that stands in for a visually hidden submit input, Turbo's
    # confirmation flow for one, relies on it becoming the active element). A
    # click already targeted at interactive content *inside* the label (the
    # control itself included) is left alone, so the forwarded click cannot
    # bounce back here. Interactive content the label is nested in — a label
    # inside an <a> or a <button> — is not a descendant, so it does not suppress
    # the forwarding.
    def activation_behavior(_event)
      labeled = control
      return if labeled.nil?

      # The nearest interactive ancestor of the click's origin, this label
      # itself excluded: a label is interactive content too, so from a click
      # on its own text `closest` reaches it — that is the ordinary case, not a
      # nested interactive element to leave alone.
      origin = _event.__js_get__("target")
      interactive = origin.closest(INTERACTIVE_CONTENT) if origin.respond_to?(:closest)
      return if interactive && !interactive.equal?(self) && contains?(interactive)

      labeled.focus if labeled.respond_to?(:focus)
      labeled.click
    end
    # `label.control` — the form control associated with this label.
    # Priority: explicit `for=`, then first form control descendant.
    def control
      target = html_for
      if __internal_has_attribute__?("for")
        # The first element in the label's own tree with that ID.
        el = __internal_tree_element_by_id__(target)
        el if el && labelable_control?(el)
      else
        # The first labelable descendant in tree order (a hidden input, being
        # non-labelable, is skipped).
        query_selector_all("button, input, meter, output, progress, select, textarea")
          .to_a.find { |c| labelable_control?(c) }
      end
    end

    # Labelable elements: button, input (except type=hidden), meter, output,
    # progress, select, textarea.
    def labelable_control?(el)
      tag = el.tag_name.to_s.downcase
      return el.type.to_s.downcase != "hidden" if tag == "input"

      %w[button meter output progress select textarea].include?(tag)
    end

    # The labeled control's form owner, or null when there is no labeled
    # control or it is not form-associated (a meter or progress).
    def form
      target = control
      target.form if target.respond_to?(:form)
    end

    js_readable :control, :form
  end

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.
  class HTMLFieldSetElement < HTMLElement
    include Internal::ConstraintValidation
    def type
      "fieldset"
    end

    def form
      __internal_form_owner__
    end

    # The listed elements among the fieldset's descendants, in tree order.
    def elements
      el = self
      @elements ||= HTMLCollection.new do
        el.query_selector_all(HTMLFormElement::LISTED_CONTROL_SELECTOR).to_a
      end
    end

    # A fieldset is not submittable, so it is barred from constraint
    # validation: willValidate is false, validationMessage is empty and
    # checkValidity/reportValidity succeed — though setCustomValidity still
    # sets validity.customError.
    def __internal_barred_from_constraint_validation__? = true

    js_readable :type, :form, :elements
  end

  # `<output>` — calculation result element.

  # `<output>` — calculation result element.

  # `<legend>` — primarily exposes its `form` back-ref.
  class HTMLLegendElement < HTMLElement
    # HTML: the legend's `form` is its parent fieldset's form owner, or null
    # when its parent is not a fieldset — it does not fall back to a <form> the
    # legend merely sits inside.
    def form
      parent = parent_element
      parent.form if parent.is_a?(HTMLFieldSetElement)
    end

    def __js_get__(key)
      key == "form" ? form : super
    end
  end

  # `<slot>` — composes light DOM into the shadow tree. Light DOM
  # children of the shadow's host get assigned to slots: those whose
  # `slot=name` attribute matches a named slot, or those without a
  # `slot` attribute go to the unnamed default slot. If nothing is
  # assigned, the slot's own children render as fallback content.

  # `<select>` — exposes `value` (selected option's value), `options`,
  # `selectedIndex`, and dispatches change events. Minimal compared to
  # happy-dom's full HTMLSelectElement, but covers common test cases.

  # `<output>` — calculation result element.
  class HTMLOutputElement < HTMLElement
    include Internal::ConstraintValidation
    js_accessor :value

    # `value` is always the descendant text content. `defaultValue` tracks a
    # separate "default value override": while the value mode flag is "default"
    # the two coincide (setting either updates the text), but once `value=` flips
    # the flag to "value" they diverge — the override is frozen and further
    # `defaultValue=` no longer touches the text content.
    def value
      text_content
    end

    def value=(v)
      if @__value_mode != :value
        @__default_override = text_content
        @__value_mode = :value
      end
      self.text_content = v.to_s
    end

    def default_value
      @__value_mode == :value ? @__default_override.to_s : text_content
    end

    def default_value=(v)
      if @__value_mode == :value
        @__default_override = v.to_s
      else
        self.text_content = v.to_s
      end
    end

    # `for` attribute is a space-separated list of IDs.
    def html_for_tokens
      reflected_string("for").split(/\s+/).reject(&:empty?)
    end

    def form
      __internal_form_owner__
    end

    def labels
      labels_node_list
    end

    def type
      "output"
    end

    # An output has a validity state (customError is settable) but is barred
    # from constraint validation.
    def __internal_barred_from_constraint_validation__? = true

    # HTML's reset algorithm for output: the value mode flag goes back to
    # "default" and the text content becomes the default value.
    def __internal_reset__
      default = default_value
      @__value_mode = :default
      @__default_override = nil
      self.text_content = default
      nil
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "defaultValue"
        default_value
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"
        self.value = v
      when "defaultValue"
        self.default_value = v
      when "htmlFor"
        set_reflected_string("for", v)
      else
        super
      end
    end
  end

  # `<legend>` — primarily exposes its `form` back-ref.

  # `<legend>` — primarily exposes its `form` back-ref.

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.
  class HTMLMeterElement < HTMLElement
    # [ReflectSetter] all six: the setters reflect, and the getters below are the
    # prose — the WHATWG "actual" values, each constrained by the ones before it.
    reflect_double_setter :min, :max, :value, :low, :high, :optimum

    # The IDL getters return the WHATWG "actual" values, constrained in order:
    # min → max (≥min) → value (∈[min,max]) → low (∈[min,max]) →
    # high (∈[low,max]) → optimum (∈[min,max]).
    def min
      numeric_attr("min", 0.0)
    end

    def max
      [numeric_attr("max", 1.0), min].max
    end

    def value
      clamp(numeric_attr("value", 0.0), min, max)
    end

    def low
      clamp(numeric_attr("low", min), min, max)
    end

    def high
      clamp(numeric_attr("high", max), low, max)
    end

    def optimum
      clamp(numeric_attr("optimum", (min + max) / 2.0), min, max)
    end

    def labels
      labels_node_list
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "min"
        min
      when "max"
        max
      when "low"
        low
      when "high"
        high
      when "optimum"
        optimum
      when "labels"
        labels
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value" then self.value = v
      when "min" then self.min = v
      when "max" then self.max = v
      when "low" then self.low = v
      when "high" then self.high = v
      when "optimum" then self.optimum = v
      else super
      end
    end

    private

    # The content attribute by the rules for parsing floating-point number
    # values, or `default` when it is missing or does not parse.
    def numeric_attr(name, default)
      parse_html_float(__internal_attribute_value__(name)) || default
    end

    def clamp(v, lo, hi)
      return lo if v < lo
      return hi if v > hi

      v
    end

  end

  # `<progress>` — `value` and `max` (default max=1). `position`
  # returns `value / max` for a "determinate" progress bar, or -1
  # when no value is set ("indeterminate").
  class HTMLProgressElement < HTMLElement
    reflect_double_setter :value
    # `max` is [ReflectPositive, ReflectDefault=1.0], declared from the IDL
    # (Internal::IdlReflection): the attribute parsed, when it is a number
    # greater than zero, else 1; the setter ignores a value that is not greater
    # than zero. This is also the bar's maximum value.

    # A progress bar is determinate iff it HAS a `value` content attribute —
    # whatever it says: `value=""` and `value="x"` are determinate with a
    # value of zero. Its value is the attribute parsed when that is a number
    # greater than zero, else 0, and its current value that clamped to the
    # maximum. The `value` getter returns the current value, or 0 when the
    # bar is indeterminate.
    def value
      return 0.0 unless determinate?

      parsed = parse_html_float(__internal_attribute_value__("value"))
      parsed = 0.0 unless parsed&.positive?
      [parsed, max].min
    end

    # `position` = current value / maximum for a determinate bar; -1 for an
    # indeterminate one.
    def position
      return -1.0 unless determinate?

      value / max
    end

    def labels
      labels_node_list
    end

    js_accessor :value
    js_readable :position, :labels

    private

    def determinate?
      !__internal_attribute_value__("value").nil?
    end
  end

  # `<template>` — `content` returns the DocumentFragment that
  # owns the template's children. Reuses the document-level
  # template_content storage so existing template handling stays
  # consistent.
end
