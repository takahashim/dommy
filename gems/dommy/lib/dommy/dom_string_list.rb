# frozen_string_literal: true

module Dommy
  # `DOMStringList` — a read-only list of strings (`location.ancestorOrigins`).
  # Live: the block is re-run on each access, so the list can be [SameObject]
  # and still answer the current strings.
  #
  # Spec: https://html.spec.whatwg.org/#the-domstringlist-interface
  class DOMStringList < LiveList
    # `item(index)` — the string at `index` (a WebIDL unsigned long), or null.
    def item(index)
      super(Internal::WebIDL.unsigned_long(index))
    end

    # `contains(string)` — whether the list holds `string`.
    def contains(string)
      @compute.call.include?(string.to_s)
    end

    alias include? contains

    js_methods %w[item contains]
    def __js_call__(method, args)
      case method
      when "item"
        raise Bridge::TypeError, "item requires 1 argument." if args.empty?

        item(args[0])
      when "contains"
        raise Bridge::TypeError, "contains requires 1 argument." if args.empty?

        contains(args[0])
      end
    end
  end
end
