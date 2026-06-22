# frozen_string_literal: true

module Dommy
  # `<canvas>` — Dommy has no raster backend, so the API surface is implemented
  # as inert stubs: `getContext('2d')` returns a CanvasRenderingContext2D whose
  # draw operations are no-ops and whose read-backs are zeroed. The point is not
  # to draw but to keep the *many* sites that merely touch a canvas from
  # crashing: sprite/asset loaders, "am I a bot" canvas fingerprints, and chart
  # libraries that feature-detect 2D support all call `getContext` then
  # `fillRect` / `createImageData` / `measureText`. With no canvas element those
  # are `undefined`, so the call throws "getContext is not a function" and aborts
  # the whole bundle — exactly what hatena's bookmark.js does, which silently
  # broke the page's bookmark button. WebGL is reported as genuinely unsupported
  # (getContext returns null) so callers take their fallback path.
  class HTMLCanvasElement < HTMLElement
    DEFAULT_WIDTH = 300
    DEFAULT_HEIGHT = 150

    # A 1x1 transparent PNG — a constant so a canvas fingerprint reads a stable
    # value instead of crashing; we render nothing into it.
    BLANK_PNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lE" \
                "QVR42mNk+M8AAAMBAQDJ/pLvAAAAAElFTkSuQmCC"

    def width = int_dimension("width", DEFAULT_WIDTH)
    def height = int_dimension("height", DEFAULT_HEIGHT)

    def width=(value)
      set_reflected_string("width", value.to_s)
    end

    def height=(value)
      set_reflected_string("height", value.to_s)
    end

    # Spec: getContext returns the SAME object across calls for one context id.
    # Only '2d' is backed; webgl/webgl2/bitmaprenderer return null so feature
    # detection cleanly fails over.
    def get_context(context_id, *_options)
      return nil unless context_id.to_s == "2d"

      @__context_2d ||= CanvasRenderingContext2D.new(self)
    end

    def to_data_url(*_args) = BLANK_PNG

    def to_blob(callback = nil, *_args)
      return nil unless callback.respond_to?(:call)

      callback.call(Blob.new([], {"type" => "image/png"}))
      nil
    end

    def __js_get__(key)
      case key
      when "width" then width
      when "height" then height
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "width", "height" then set_reflected_string(key, value.to_s)
      else super
      end
    end

    include Bridge::Methods
    js_methods %w[getContext toDataURL toBlob]
    def __js_call__(method, args)
      case method
      when "getContext" then get_context(args[0], *args[1..])
      when "toDataURL" then to_data_url(*args)
      when "toBlob" then to_blob(*args)
      else super
      end
    end

    private

    def int_dimension(attr, default)
      raw = @__node__[attr]
      raw.nil? || raw.to_s.empty? ? default : raw.to_s.to_i
    end
  end

  # The 2D drawing context — every drawing call is a no-op, state setters are
  # remembered (so `ctx.fillStyle` round-trips), and read-backs return zeroed
  # data of the right shape. Enough for asset loaders / fingerprint probes /
  # chart feature-detection to run without throwing.
  class CanvasRenderingContext2D
    # Drawing-state attributes that round-trip a value (default per spec where it
    # matters; a plain "" otherwise).
    STATE_DEFAULTS = {
      "fillStyle" => "#000000", "strokeStyle" => "#000000",
      "globalAlpha" => 1.0, "globalCompositeOperation" => "source-over",
      "lineWidth" => 1.0, "lineCap" => "butt", "lineJoin" => "miter", "miterLimit" => 10.0,
      "lineDashOffset" => 0.0, "font" => "10px sans-serif", "textAlign" => "start",
      "textBaseline" => "alphabetic", "direction" => "inherit",
      "shadowBlur" => 0.0, "shadowColor" => "rgba(0, 0, 0, 0)",
      "shadowOffsetX" => 0.0, "shadowOffsetY" => 0.0,
      "imageSmoothingEnabled" => true, "imageSmoothingQuality" => "low", "filter" => "none"
    }.freeze

    def initialize(canvas)
      @canvas = canvas
      @state = STATE_DEFAULTS.dup
    end

    def __js_get__(key)
      return @canvas if key == "canvas"
      return @state[key] if @state.key?(key)

      Bridge::ABSENT
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless @state.key?(key)

      @state[key] = value
      value
    end

    include Bridge::Methods
    js_methods %w[
      save restore scale rotate translate transform setTransform resetTransform getTransform
      beginPath closePath moveTo lineTo bezierCurveTo quadraticCurveTo arc arcTo ellipse rect roundRect
      fill stroke clip fillRect strokeRect clearRect fillText strokeText drawImage putImageData
      setLineDash drawFocusIfNeeded scrollPathIntoView reset
      getLineDash measureText createLinearGradient createRadialGradient createConicGradient
      createPattern getImageData createImageData isPointInPath isPointInStroke getContextAttributes
    ]
    def __js_call__(method, args)
      case method
      # All drawing/state-machine operations: nothing is painted.
      when "save", "restore", "scale", "rotate", "translate", "transform", "setTransform",
           "resetTransform", "getTransform", "beginPath", "closePath", "moveTo", "lineTo",
           "bezierCurveTo", "quadraticCurveTo", "arc", "arcTo", "ellipse", "rect", "roundRect",
           "fill", "stroke", "clip", "fillRect", "strokeRect", "clearRect", "fillText", "strokeText",
           "drawImage", "putImageData", "setLineDash", "drawFocusIfNeeded", "scrollPathIntoView", "reset"
        nil
      when "getLineDash" then []
      when "measureText" then TextMetrics.new(args[0].to_s)
      when "createLinearGradient", "createRadialGradient", "createConicGradient", "createPattern"
        CanvasGradient.new
      when "getImageData" then ImageData.new(args[2].to_i.abs, args[3].to_i.abs)
      when "createImageData" then created_image_data(args)
      when "isPointInPath", "isPointInStroke" then false
      when "getContextAttributes" then {}
      end
    end

    private

    # createImageData(imagedata) clones its dimensions; createImageData(w, h)
    # builds a blank one. A zero/blank size still yields a valid 0-length buffer.
    def created_image_data(args)
      first = args[0]
      if first.respond_to?(:__js_get__) && !first.__js_get__("width").equal?(Bridge::ABSENT)
        ImageData.new(first.__js_get__("width").to_i, first.__js_get__("height").to_i)
      else
        ImageData.new(first.to_i.abs, args[1].to_i.abs)
      end
    end
  end

  # `ctx.measureText(...)` result. width is an approximation (no font metrics);
  # the extended box metrics are zero. Enough that callers reading `.width`
  # don't divide by undefined.
  class TextMetrics
    APPROX_CHAR_WIDTH = 6

    def initialize(text)
      @width = text.to_s.length * APPROX_CHAR_WIDTH
    end

    def __js_get__(key)
      case key
      when "width" then @width
      when "actualBoundingBoxLeft", "actualBoundingBoxRight",
           "actualBoundingBoxAscent", "actualBoundingBoxDescent",
           "fontBoundingBoxAscent", "fontBoundingBoxDescent",
           "emHeightAscent", "emHeightDescent",
           "hangingBaseline", "alphabeticBaseline", "ideographicBaseline" then 0
      else Bridge::ABSENT
      end
    end

    def __js_set__(_key, _value) = Bridge::UNHANDLED
  end

  # A gradient/pattern handle. addColorStop is a no-op (nothing is painted).
  class CanvasGradient
    def __js_get__(_key) = Bridge::ABSENT
    def __js_set__(_key, _value) = Bridge::UNHANDLED

    include Bridge::Methods
    js_methods %w[addColorStop setTransform]
    def __js_call__(method, _args)
      case method
      when "addColorStop", "setTransform" then nil
      end
    end
  end

  # `ctx.getImageData(...)` / `createImageData(...)` result: width, height, and a
  # zeroed RGBA `data` buffer of length width*height*4 (a plain numeric array,
  # which supports the `.length` and `data[i]` reads canvas code does).
  class ImageData
    attr_reader :width, :height

    def initialize(width, height)
      @width = [width.to_i, 0].max
      @height = [height.to_i, 0].max
      @data = Array.new(@width * @height * 4, 0)
    end

    def __js_get__(key)
      case key
      when "width" then @width
      when "height" then @height
      when "data" then @data
      when "colorSpace" then "srgb"
      else Bridge::ABSENT
      end
    end

    def __js_set__(_key, _value) = Bridge::UNHANDLED
  end
end
