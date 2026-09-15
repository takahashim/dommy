# frozen_string_literal: true

module Dommy
  # `StaticRange` — a range that does not follow the tree. Its boundary points
  # stay where they were put, and nothing checks that they still make sense: an
  # offset past its node's length is allowed, and so are two points in
  # different trees. Scripts construct one with `new StaticRange(init)`, and
  # Selection#get_composed_ranges hands them out.
  #
  # Spec: https://dom.spec.whatwg.org/#interface-staticrange
  class StaticRange
    INIT_MEMBERS = %w[startContainer startOffset endContainer endOffset].freeze

    attr_reader :start_container, :start_offset, :end_container, :end_offset

    # `new StaticRange(init)`. `init` is the JS dictionary as it crosses the
    # bridge: every member is required, a container must be a Node, and a
    # DocumentType or Attr cannot be one.
    def self.from_init(init)
      raise Bridge::TypeError, "StaticRangeInit must be an object" unless init.is_a?(Hash)

      missing = INIT_MEMBERS.select { |key| init.fetch(key, Bridge::UNDEFINED).equal?(Bridge::UNDEFINED) }
      raise Bridge::TypeError, "StaticRangeInit is missing #{missing.join(", ")}" unless missing.empty?

      start_container = Internal::WebIDL.node!(init["startContainer"])
      end_container = Internal::WebIDL.node!(init["endContainer"])
      if [start_container, end_container].any? { |node| node.is_a?(DocumentType) || node.is_a?(Attr) }
        raise DOMException::InvalidNodeTypeError, "a DocumentType or Attr cannot be a boundary point"
      end

      new(start_container, Internal::WebIDL.unsigned_long(init["startOffset"]),
          end_container, Internal::WebIDL.unsigned_long(init["endOffset"]))
    end

    def initialize(start_container, start_offset, end_container, end_offset)
      @start_container = start_container
      @start_offset = start_offset
      @end_container = end_container
      @end_offset = end_offset
    end

    def collapsed?
      @start_container.equal?(@end_container) && @start_offset == @end_offset
    end

    alias collapsed collapsed?

    def __js_get__(key)
      case key
      when "startContainer"
        @start_container
      when "startOffset"
        @start_offset
      when "endContainer"
        @end_container
      when "endOffset"
        @end_offset
      when "collapsed"
        collapsed?
      else
        Bridge::ABSENT
      end
    end
  end
end
