# frozen_string_literal: true

require_relative "url_parser"

module Dommy
  module Internal
    # WHATWG URLUtils-style getter/setter pairs shared by `Dommy::URL` and
    # `Dommy::Location`, both of which hold their state as an
    # `Internal::UrlParser::Record` in `@record`. Host/hostname/port/protocol/
    # pathname normalize identically for both classes, so they live here once
    # instead of being hand-copied between the two files.
    #
    # `search`/`hash` are deliberately NOT here: their setters diverge (`URL`
    # also re-syncs `URLSearchParams`; `Location` fires `hashchange`), and a
    # method literally named `hash` would shadow `Object#hash` on whichever
    # class includes this module — too risky to share just to save a few
    # lines.
    #
    # Including class must maintain `@record`; getters/setters here are
    # public by default — a class that wants them private (`Location` does)
    # marks them so after `include`.
    module UrlRecordAccessors
      def protocol
        "#{@record.scheme}:"
      end

      def protocol=(value)
        parse_into("#{value}:", :scheme_start)
      end

      def host
        return "" if @record.host.nil?

        @record.port ? "#{@record.host}:#{@record.port}" : @record.host
      end

      def host=(value)
        return if @record.opaque_path?

        parse_into(value, :host)
      end

      def hostname
        @record.host.to_s
      end

      def hostname=(value)
        return if @record.opaque_path?

        parse_into(value, :hostname)
      end

      def port
        @record.port.nil? ? "" : @record.port.to_s
      end

      def port=(value)
        return if cannot_have_credentials?

        v = value.to_s
        v.empty? ? (@record.port = nil) : parse_into(v, :port)
      end

      def pathname
        Internal::UrlParser.serialize_path(@record)
      end

      def pathname=(value)
        return if @record.opaque_path?

        @record.path = []
        parse_into(value, :path_start)
      end

      private

      def cannot_have_credentials?
        @record.host.nil? || @record.host == "" || @record.scheme == "file"
      end

      # Run the parser from `state` into the current record; a rejected value
      # changes nothing (WHATWG URLUtils setters).
      def parse_into(value, state)
        Internal::UrlParser.parse_with_override(value.to_s, @record, state)
      rescue Internal::UrlParser::Failure
        nil
      end
    end
  end
end
