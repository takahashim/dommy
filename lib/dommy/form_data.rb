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
      end
    end

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
    # Per spec, the submitter (clicked button) is included only when
    # the user passes it explicitly; we don't model that here.
    def collect_from(form)
      form.elements.each do |el|
        next unless el.respond_to?(:name)

        name = el.name.to_s
        next if name.empty?
        next if disabled?(el)

        case el.__node__.name
        when "input"
          collect_input(el, name)
        when "select"
          collect_select(el, name)
        when "textarea", "button", "output"
          @pairs << [name, el.value.to_s] if el.respond_to?(:value)
        end
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

      when "checkbox", "radio"
        @pairs << [name, (el.value.to_s.empty? ? "on" : el.value.to_s)] if el.checked
      else
        @pairs << [name, el.value.to_s]
      end
    end

    def collect_select(el, name)
      if el.multiple
        el.selected_options.each { |opt| @pairs << [name, opt.value.to_s] }
      else
        opt = el.selected_options[0]
        @pairs << [name, opt ? opt.value.to_s : ""]
      end
    end

    def disabled?(el)
      el.respond_to?(:disabled) && el.disabled
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
