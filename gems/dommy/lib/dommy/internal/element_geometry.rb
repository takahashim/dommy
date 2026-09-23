# frozen_string_literal: true

module Dommy
  module Internal
    # getBoundingClientRect and friends. Dommy lays nothing out, so these
    # answer from an approximation; the scroll log is what a test reads back.
    #
    # Element's, but not about being an element: it was 2200 lines holding
    # these four subjects alongside attributes, selectors and serialization.
    module ElementGeometry
      # No real layout engine. By default geometry getters return zeroed rects;
      # when the window opts into approximate geometry (window.approximate_layout)
      # they return non-zero estimates from a cheap pseudo-layout so a site that
      # treats an all-zero rect as "the DOM is broken" can proceed.
      def get_bounding_client_rect
        approximate_layout? ? DOMRect.new(**__internal_approx_box) : DOMRect.new
      end

      def get_client_rects
        return [] unless approximate_layout?
  
        box = __internal_approx_box
        box[:width].positive? || box[:height].positive? ? [DOMRect.new(**box)] : []
      end

      # Test inspector for scroll calls (no real layout to scroll).
      def __test_scroll_log__
        @scroll_log ||= []
      end

      # No real layout — record the scroll request so tests can assert it.
      def record_scroll(name, args)
        @scroll_log ||= []
        @scroll_log << [name, args]
        nil
      end

      def __internal_approx_box
        viewport = @document&.default_view&.inner_width.to_i
        viewport = 1280 if viewport <= 0
        text = text_content.to_s
        content_px = text.length * APPROX_CHAR_PX
        if INLINE_TAGS.include?(local_name.to_s.downcase)
          {x: 0, y: 0, width: [content_px, viewport].min, height: text.empty? ? 0 : APPROX_LINE_PX}
        else
          lines = text.empty? ? 0 : [(content_px.to_f / viewport).ceil, 1].max
          {x: 0, y: 0, width: viewport, height: lines * APPROX_LINE_PX}
        end
      end

      def approximate_layout? = !!@document&.default_view&.approximate_layout
  
      # Estimate {x, y, width, height} (CSS px) without laying out the page: block
      # elements fill the viewport width; inline elements are sized to their text;
      # height is the wrapped line count × a nominal line height. Position is the
      # origin (we don't position elements). Used only when approximate_layout?.
      INLINE_TAGS = %w[a span b i em strong small code label abbr cite q sub sup time mark u s
                       tt var samp kbd bdi bdo wbr big font nobr].freeze
      APPROX_CHAR_PX = 8
      APPROX_LINE_PX = 20
      end
  end
end
