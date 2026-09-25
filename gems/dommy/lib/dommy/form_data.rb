# frozen_string_literal: true

module Dommy
  # `FormData` — collects name/value entries from an `<form>` (or
  # programmatically), preserving insertion order. Values are
  # stringified per spec; `File` values are passed through as-is
  # (Dommy has no File class, so this only matters for embedders
  # that supply their own).
  #
  # Usage:
  #   fd = Dommy::FormData.new(form)
  #   fd.get("email")          # "alice@x.test"
  #   fd.append("tag", "ruby")
  #   fd.entries               # [["email", "..."], ["tag", "ruby"]]
  class FormData
    include Enumerable

    # `new FormData(form)` from JavaScript: an absent or undefined form means
    # an empty FormData; null or anything but a form element is a TypeError,
    # since the argument is a non-nullable HTMLFormElement.
    def self.from_js(args)
      return new if args.empty? || args[0].equal?(Bridge::UNDEFINED)
      raise Bridge::TypeError, "FormData constructor: argument 1 is not an HTMLFormElement" unless args[0].is_a?(HTMLFormElement)

      new(args[0])
    end

    def initialize(form = nil)
      @pairs = []
      collect_from(form) if form
    end

    def append(name, value, _filename = nil)
      @pairs << [name.to_s, stringify(value)]
      nil
    end

    def set(name, value, _filename = nil)
      key = name.to_s
      v = stringify(value)
      replaced = false
      @pairs = @pairs.flat_map do |k, existing|
        if k == key
          if replaced
            []
          else
            replaced = true
            [[key, v]]
          end
        else
          [[k, existing]]
        end
      end

      @pairs << [key, v] unless replaced
      nil
    end

    def get(name)
      pair = @pairs.find { |k, _| k == name.to_s }
      pair && pair[1]
    end

    def get_all(name)
      @pairs.select { |k, _| k == name.to_s }.map { |_, v| v }
    end

    alias getAll get_all

    def has(name)
      @pairs.any? { |k, _| k == name.to_s }
    end

    alias has? has

    def delete(name)
      @pairs.reject! { |k, _| k == name.to_s }
      nil
    end

    def keys
      @pairs.map { |k, _| k }
    end

    def values
      @pairs.map { |_, v| v }
    end

    def entries
      @pairs.dup
    end

    def for_each(&block)
      @pairs.each { |k, v| block.call(v, k, self) }
      nil
    end

    alias forEach for_each

    def each(&block)
      @pairs.each(&block)
    end

    def size
      @pairs.length
    end

    alias length size

    def to_s
      @pairs.map { |k, v| "#{k}=#{v}" }.join("&")
    end

    def __js_get__(key)
      case key
      when "size", "length"
        size
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[append set get getAll has delete keys values entries forEach]
    def __js_call__(method, args)
      case method
      when "append"
        append(args[0], args[1], args[2])
      when "set"
        set(args[0], args[1], args[2])
      when "get"
        get(args[0])
      when "getAll"
        get_all(args[0])
      when "has"
        has(args[0])
      when "delete"
        delete(args[0])
      when "keys"
        keys
      when "values"
        values
      when "entries"
        entries
      when "forEach"
        for_each(&args[0])
      end
    end

    private

    # Collect submittable name/value pairs from a form element.
    #
    # A submit button is NOT one of them: HTML's "constructing the entry list"
    # includes only the submitter, which this does not model, so a named
    # <button> contributes nothing — including one associated with the form from
    # outside it by a `form` attribute. That used to happen by accident, because
    # HTMLButtonElement had no Ruby `value` method for `respond_to?` to find;
    # it is a rule now, so declaring `value` as the reflection it is cannot
    # quietly put every button in the entry list.
    def collect_from(form)
      form.elements.each do |el|
        next unless el.respond_to?(:name)

        name = el.name.to_s
        next if name.empty?
        next if disabled?(el)

        case el.__dommy_backend_node__.name
        when "input"
          collect_input(el, name)
        when "select"
          collect_select(el, name)
        when "textarea", "output"
          @pairs << [name, el.value.to_s] if el.respond_to?(:value)
        end
        append_dirname(el)
      end
    end

    def collect_input(el, name)
      type = el.type.to_s.downcase
      case type
      when "submit", "reset", "button", "image"
        # submit/button: only the activated submitter is included (skip).
        nil
      when "file"
        # Each File in the input's FileList becomes its own entry, per
        # the HTML "constructing the entry list" spec. An empty list
        # contributes a single empty File-like entry so name= survives.
        files = el.respond_to?(:files) ? el.files : nil
        if files && !files.empty?
          files.each { |f| @pairs << [name, f] }
        else
          @pairs << [name, File.new([], "", "type" => "application/octet-stream")]
        end

      when "hidden"
        # A `_charset_` hidden field with no value reports the encoding this
        # FormData is constructed with (the constructor's default is UTF-8).
        if !el.has_attribute?("value") && name.casecmp?("_charset_")
          @pairs << [name, Encoding::UTF_8.name]
        else
          @pairs << [name, el.value.to_s]
        end
      when "checkbox", "radio"
        @pairs << [name, (el.value.to_s.empty? ? "on" : el.value.to_s)] if el.checked
      else
        @pairs << [name, el.value.to_s]
      end
    end

    # A `dirname` on an auto-directionality text control contributes the
    # element's directionality under the dirname's name (HTML §4.10.19.2).
    def append_dirname(el)
      return unless %w[input textarea].include?(el.__dommy_backend_node__.name)

      dirname = el.get_attribute("dirname")
      return if dirname.nil? || dirname.empty?
      return unless Internal::Directionality.auto_directionality_form_associated?(el)

      @pairs << [dirname, Internal::Directionality.direction_of(el)]
    end

    def collect_select(el, name)
      el.selected_options.each do |opt|
        next if Internal::ElementState.disabled_element?(opt)

        @pairs << [name, opt.value.to_s]
      end
    end

    def disabled?(el)
      Internal::ElementState.disabled_element?(el)
    end

    def stringify(value)
      # File / Blob values pass through unchanged (multipart form
      # encoding handles them); other values are stringified per spec.
      return value if value.is_a?(Blob)
      return "" if value.nil?

      value.to_s
    end
  end
end
