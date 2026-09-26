# frozen_string_literal: true

module Dommy
  # `DataTransfer` — the payload object on a DragEvent. Holds the
  # files being dragged plus arbitrary string-keyed data per MIME
  # format. Tests build one explicitly to simulate drag-and-drop:
  #
  #   dt = Dommy::DataTransfer.new(files: [file])
  #   ev = Dommy::DragEvent.new("drop", "dataTransfer" => dt, "bubbles" => true)
  #   target.dispatch_event(ev)
  #
  # Spec: https://html.spec.whatwg.org/multipage/dnd.html#datatransfer
  class DataTransfer
    attr_reader :files

    def initialize(files: [], data: {})
      @files = files.is_a?(FileList) ? files : FileList.new(Array(files))
      @data = data.transform_keys { |k| normalize_format(k) }
      @drop_effect = "none"
      @effect_allowed = "uninitialized"
    end

    def types
      @data.keys
    end

    def get_data(format)
      @data[normalize_format(format)].to_s
    end

    def set_data(format, data)
      @data[normalize_format(format)] = data.to_s
      nil
    end

    def clear_data(format = nil)
      if format
        @data.delete(normalize_format(format))
      else
        @data.clear
      end

      nil
    end

    attr_accessor :drop_effect, :effect_allowed

    def items
      @items ||= DataTransferItemList.new(self)
    end

    # Called by the item list when a File/Blob is added through `items.add`.
    # FileList is immutable, so rebuild it with the new file appended.
    def __internal_add_file__(file)
      @files = FileList.new(@files.to_a + [file])
      nil
    end

    def __js_get__(key)
      case key
      when "files"
        @files
      when "items"
        items
      when "types"
        types
      when "dropEffect"
        @drop_effect
      when "effectAllowed"
        @effect_allowed
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "dropEffect"
        @drop_effect = value.to_s
      when "effectAllowed"
        @effect_allowed = value.to_s
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[getData setData clearData]
    def __js_call__(method, args)
      case method
      when "getData"
        get_data(args[0])
      when "setData"
        set_data(args[0], args[1])
      when "clearData"
        clear_data(args[0])
      end
    end

    private

    # Per spec, "text" maps to "text/plain" and "url" maps to
    # "text/uri-list"; otherwise lowercase the MIME format.
    def normalize_format(format)
      case format.to_s.downcase
      when "text"
        "text/plain"
      when "url"
        "text/uri-list"
      else
        format.to_s.downcase
      end
    end
  end

  # `DataTransferItemList` — `dataTransfer.items`. The tests build one to seed a
  # file input: `dt.items.add(file); input.files = dt.files`. A Blob/File adds a
  # file item (and appends to `files`); anything else adds a string item.
  class DataTransferItemList
    include Bridge::Methods
    js_methods %w[add remove clear]

    def initialize(owner)
      @owner = owner
      @items = []
    end

    def add(data, type = nil)
      item = DataTransferItem.new(data, type)
      @items << item
      if data.is_a?(Blob)
        @owner.__internal_add_file__(data)
      else
        @owner.set_data(type.to_s.empty? ? "text/plain" : type.to_s, data.to_s)
      end
      item
    end

    def remove(index)
      @items.delete_at(index.to_i)
      nil
    end

    def clear
      @items.clear
      nil
    end

    def length = @items.length

    def __js_get__(key)
      return length if key == "length"

      index = Integer(key, exception: false)
      return Bridge::ABSENT unless index&.between?(0, @items.length - 1)

      @items[index]
    end

    def __js_call__(method, args)
      case method
      when "add" then add(args[0], args[1])
      when "remove" then remove(args[0])
      when "clear" then clear
      end
    end
  end

  # `DataTransferItem` — one entry in the list, a file or a string item.
  class DataTransferItem
    include Bridge::Methods
    js_methods %w[getAsFile getAsString]

    def initialize(data, type = nil)
      @data = data
      @type = if type.to_s.empty?
        data.is_a?(Blob) ? data.type.to_s : "text/plain"
      else
        type.to_s
      end
    end

    def kind = @data.is_a?(Blob) ? "file" : "string"
    def type = @type

    def get_as_file = @data.is_a?(Blob) ? @data : nil

    def get_as_string(callback)
      callback&.call(@data.to_s)
      nil
    end

    def __js_get__(key)
      case key
      when "kind" then kind
      when "type" then type
      else Bridge::ABSENT
      end
    end

    def __js_call__(method, args)
      case method
      when "getAsFile" then get_as_file
      when "getAsString" then get_as_string(args[0])
      end
    end
  end
end
