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

    def __js_get__(key)
      case key
      when "files"
        @files
      when "types"
        types
      when "dropEffect"
        @drop_effect
      when "effectAllowed"
        @effect_allowed
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
end
