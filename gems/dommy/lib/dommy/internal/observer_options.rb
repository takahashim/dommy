# frozen_string_literal: true

module Dommy
  module Internal
    # A MutationObserverInit dictionary, normalized. Reading one is three
    # separate jobs the spec spells out in one step — implied members, the
    # TypeErrors a contradictory dictionary raises, and the registration it
    # becomes — which is why #observe was forty lines of unpacking before it got
    # to observing anything.
    #
    # `attributes` is implied true when attributeFilter or attributeOldValue is
    # supplied AND the member itself is omitted; `characterData` likewise from
    # characterDataOldValue. Supplying the companion while saying the member is
    # false is a TypeError, not an implication.
    class ObserverOptions
      def initialize(options)
        @opts = options.is_a?(Hash) ? options : {}
      end

      def to_registration(target)
        reject_contradictions!
        unless child_list? || attributes? || character_data?
          raise Bridge::TypeError,
            "MutationObserver.observe: at least one of childList, attributes, characterData must be true"
        end

        {
          target: target,
          child_list: child_list?,
          subtree: flag("subtree"),
          attributes: attributes?,
          attribute_filter: attribute_filter,
          attribute_old_value: flag("attributeOldValue"),
          character_data: character_data?,
          character_data_old_value: flag("characterDataOldValue")
        }
      end

      private

      def attribute_filter
        filter = @opts["attributeFilter"] || @opts[:attributeFilter]
        filter.is_a?(Array) ? filter.map { |name| name.to_s.downcase } : filter
      end

      def child_list? = flag("childList")
      def attributes? = flag("attributes") || (attribute_extras? && !given?("attributes"))
      def character_data? = flag("characterData") || (character_data_extras? && !given?("characterData"))

      def attribute_extras? = !attribute_filter.nil? || flag("attributeOldValue")
      def character_data_extras? = flag("characterDataOldValue")

      def reject_contradictions!
        if attribute_extras? && given?("attributes") && !flag("attributes")
          raise Bridge::TypeError, "attributeOldValue/attributeFilter requires attributes to be true"
        end
        return unless character_data_extras? && given?("characterData") && !flag("characterData")

        raise Bridge::TypeError, "characterDataOldValue requires characterData to be true"
      end

      def given?(name) = @opts.key?(name) || @opts.key?(name.to_sym)

      # JS truthiness for a dictionary member, which is what WebIDL's `boolean`
      # conversion amounts to here.
      def flag(name)
        value = @opts.key?(name) ? @opts[name] : @opts[name.to_sym]
        return false if value.nil? || value == false || value == 0 || value == ""
        return false if defined?(Bridge::UNDEFINED) && value.equal?(Bridge::UNDEFINED)
        return false if value.is_a?(Float) && value.nan?

        true
      end
    end
  end
end
