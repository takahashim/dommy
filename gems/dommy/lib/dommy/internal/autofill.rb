# frozen_string_literal: true

module Dommy
  module Internal
    # HTML §4.10.19.7.1's "autofill processing model" (form-control-infrastructure
    # §4.10.19.7.1), for exactly the one thing Dommy needs from it: the
    # `autocomplete` IDL attribute's getter, "the element's IDL-exposed autofill
    # value" — [ReflectSetter], so the setter reflects the content attribute
    # verbatim but the getter is entirely prose. Applies to `<input>`,
    # `<textarea>`, and `<select>`.
    #
    # The algorithm also derives an autofill field name, hint set, scope, and
    # non-autofill credential type — inputs to a real autofill feature Dommy
    # does not have (no UI, no saved user data, no navigator.credentials
    # integration), so those are not computed or stored. Only the token
    # parsing needed to reach the IDL-exposed value is implemented.
    module Autofill
      # "Determine a field's category" (form-control-infrastructure
      # §4.10.19.7.1): each autofill detail token names its own category and
      # the maximum number of tokens an attribute value naming it may have.
      NORMAL_FIELD_NAMES = %w[
        name honorific-prefix given-name additional-name family-name honorific-suffix
        nickname organization-title username new-password current-password
        one-time-code organization street-address address-line1 address-line2
        address-line3 address-level4 address-level3 address-level2 address-level1
        country country-name postal-code cc-name cc-given-name cc-additional-name
        cc-family-name cc-number cc-exp cc-exp-month cc-exp-year cc-csc cc-type
        transaction-currency transaction-amount language bday bday-day bday-month
        bday-year sex url photo
      ].freeze

      CONTACT_FIELD_NAMES = %w[
        tel tel-country-code tel-national tel-area-code tel-local tel-local-prefix
        tel-local-suffix tel-extension email impp
      ].freeze

      FIELD_CATEGORIES = {
        "off" => [:off, 1],
        "on" => [:automatic, 1],
        **NORMAL_FIELD_NAMES.to_h { |name| [name, [:normal, 3]] },
        **CONTACT_FIELD_NAMES.to_h { |name| [name, [:contact, 4]] },
        "webauthn" => [:credential, 5],
      }.freeze

      # The optional "home"/"work"/... prefix a Contact field may take, and the
      # "shipping"/"billing" prefix any field may take — both listed in their
      # canonical spelling, which the IDL value uses regardless of the
      # attribute's own casing.
      CONTACT_PREFIXES = %w[home work mobile fax pager].freeze
      MODE_PREFIXES = %w[shipping billing].freeze

      module_function

      # The `autocomplete` IDL getter's value for a content attribute whose raw
      # string is `raw` (nil when absent). `anchor_mantle:` is true only for an
      # input whose type is in the Hidden state — HTML's one case where the
      # attribute wears the "autofill anchor mantle" rather than the "autofill
      # expectation mantle", under which a bare "on"/"off" is not a keyword but
      # an (invalid) autofill detail token, so it is rejected (falls through to
      # the empty string) rather than returned as-is.
      def idl_exposed_value(raw, anchor_mantle: false)
        return "" if raw.nil?

        tokens = raw.to_s.split(/[\t\n\f\r ]+/).reject(&:empty?)
        return "" if tokens.empty?

        catch(:default) { run(tokens, anchor_mantle) } || ""
      end

      # Everything above is the module; everything below is how.

      # The algorithm's main body, from "let index be the index of the last
      # token" onward — the empty-attribute and empty-tokens short circuits
      # (both of which return the empty string) are the caller's job. A
      # `throw :default` anywhere below unwinds straight past this method to
      # `idl_exposed_value`'s `catch`, which is the algorithm's "jump to the
      # step labeled default" (whose own body — resetting hint set and scope,
      # and deriving the autofill field name — has no bearing on the
      # IDL-exposed value, already implicitly the empty string via `|| ""`).
      # `throw :done` instead short-circuits just the trailing prefix-peeling
      # (webauthn / contact kind / shipping-billing / section-*) once nothing
      # is left to peel, landing on `idl_value` as accumulated so far — the
      # algorithm's "Done" label.
      def run(tokens, anchor_mantle)
        index = tokens.length - 1
        field = tokens[index]
        category, max_tokens = field_category(field)
        throw :default if category.nil? || tokens.length > max_tokens
        throw :default if anchor_mantle && (category == :off || category == :automatic)
        return "off" if category == :off
        return "on" if category == :automatic

        idl_value = field
        catch(:done) do
          if category == :credential
            # Only "webauthn" is Credential, so this is that field itself; fold
            # in the field it modifies (e.g. "current-password").
            throw :done if index.zero?

            index -= 1
            category, max_tokens = field_category(tokens[index])
            throw :default unless category == :normal || category == :contact
            throw :default if index > max_tokens - 1

            idl_value = "#{tokens[index]} #{idl_value}"
          end

          throw :done if index.zero?
          index -= 1

          if category == :contact && (contact = CONTACT_PREFIXES.find { |name| tokens[index].casecmp?(name) })
            idl_value = "#{contact} #{idl_value}"
            throw :done if index.zero?
            index -= 1
          end

          if (mode = MODE_PREFIXES.find { |name| tokens[index].casecmp?(name) })
            idl_value = "#{mode} #{idl_value}"
            throw :done if index.zero?
            index -= 1
          end

          throw :default unless index.zero?
          throw :default unless tokens[index][0, 8].casecmp?("section-")

          idl_value = "#{tokens[index].downcase(:ascii)} #{idl_value}"
        end

        idl_value
      end

      # [category, maximum tokens] for `token` (form-control-infrastructure's
      # "determine a field's category"), or [nil, nil] when it names none.
      def field_category(token)
        FIELD_CATEGORIES[token.downcase(:ascii)] || [nil, nil]
      end

      private_class_method :run, :field_category
    end
  end
end
