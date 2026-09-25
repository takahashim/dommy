# frozen_string_literal: true

module Dommy
  # `FormData` — collects name/value entries from an `<form>` (or
  # programmatically), preserving insertion order. Values are
  # stringified per spec; `File` values are passed through as-is.
  #
  # A `new FormData(form)` builds its entries through the shared
  # `Dommy::FormEntryList`, so it fires the same `formdata` event form submission
  # does and collects identically.
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
      @pairs = form ? FormEntryList.new(form).form_data.entries : []
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

    def stringify(value)
      # File / Blob values pass through unchanged (multipart form
      # encoding handles them); other values are stringified per spec.
      return value if value.is_a?(Blob)
      return "" if value.nil?

      value.to_s
    end
  end
end
