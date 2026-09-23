# frozen_string_literal: true

module Dommy
  module Internal
    # A MutationObserverInit dictionary, normalized. Reading one is three
    # separate jobs the spec spells out in one step — implied members, the
    # TypeErrors a contradictory dictionary raises, and the registration it
    # becomes — which is why #observe was forty lines of unpacking before it got
    # to observing anything.
    #
    # `attributes` is implied true when attributeFilter or attributeOldValue
    # EXISTS and the member itself is omitted; `characterData` likewise from
    # characterDataOldValue. Existence, not truth: `observe(el,
    # {attributeOldValue: false})` observes attributes, because the member is
    # there. Reading the companion's value instead is what made that call raise
    # "at least one of childList, attributes, characterData must be true"
    # (MutationObserver-sanity.html).
    #
    # Saying the member is false while supplying the companion is a TypeError
    # instead of an implication — but only for a companion that asks for
    # something: `attributeOldValue: true`, or an attributeFilter at all.
    class ObserverOptions
      def initialize(options)
        @opts = options.is_a?(Hash) ? options : {}
      end

      # The spec's steps 1-6, in their order: the implications are in the
      # readers below, then "at least one", then the contradictions.
      def to_registration(target)
        unless child_list? || attributes? || character_data?
          raise Bridge::TypeError,
            "MutationObserver.observe: at least one of childList, attributes, characterData must be true"
        end
        reject_contradictions!

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

      # Steps 1 and 2: a member that is there answers for itself; one that is
      # not is implied by its companions being there.
      def attributes? = given?("attributes") ? flag("attributes") : attribute_extras?
      def character_data? = given?("characterData") ? flag("characterData") : character_data_extras?

      def attribute_extras? = given?("attributeOldValue") || given?("attributeFilter")
      def character_data_extras? = given?("characterDataOldValue")

      # Steps 4-6. Reachable only for a member that was supplied as false: had
      # it been omitted, the companion would have implied it true above.
      def reject_contradictions!
        unless attributes?
          if flag("attributeOldValue")
            raise Bridge::TypeError, "attributeOldValue requires attributes to be true"
          end
          raise Bridge::TypeError, "attributeFilter requires attributes to be true" if given?("attributeFilter")
        end
        return if character_data? || !flag("characterDataOldValue")

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
