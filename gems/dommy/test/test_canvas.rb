# frozen_string_literal: true

require_relative "test_helper"

# Dommy has no raster backend, but the <canvas> API surface must EXIST so the
# many scripts that merely touch a canvas (asset loaders, fingerprints, charts
# feature-detecting 2d support) don't throw "getContext is not a function" and
# abort — which is what broke hatena's bookmark button.
class TestCanvas < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window("<canvas id='c' width='2' height='3'></canvas>").document
    @canvas = @doc.get_element_by_id("c")
    @ctx = @canvas.__js_call__("getContext", ["2d"])
  end

  def test_canvas_is_an_html_canvas_element
    assert_kind_of(Dommy::HTMLCanvasElement, @canvas)
    assert_equal(2, @canvas.__js_get__("width"))
    assert_equal(3, @canvas.__js_get__("height"))
  end

  def test_width_height_default_when_unset
    bare = @doc.create_element("canvas")
    assert_equal(300, bare.__js_get__("width"))
    assert_equal(150, bare.__js_get__("height"))
  end

  def test_get_context_2d_is_stable_and_other_contexts_are_null
    assert_kind_of(Dommy::CanvasRenderingContext2D, @ctx)
    assert_same(@ctx, @canvas.__js_call__("getContext", ["2d"]), "same context object across calls")
    assert_nil(@canvas.__js_call__("getContext", ["webgl"]))
    assert_nil(@canvas.__js_call__("getContext", ["bitmaprenderer"]))
  end

  def test_drawing_state_round_trips_and_draw_ops_are_noops
    @ctx.__js_set__("fillStyle", "rgba(0,0,0,0)")
    assert_equal("rgba(0,0,0,0)", @ctx.__js_get__("fillStyle"))
    # The exact crashing call from bookmark.js — must be a harmless no-op now.
    assert_nil(@ctx.__js_call__("fillRect", [0, 0, 1, 1]))
    assert_nil(@ctx.__js_call__("beginPath", []))
    assert_equal("10px sans-serif", @ctx.__js_get__("font")) # a spec default
  end

  def test_get_image_data_returns_a_zeroed_rgba_buffer
    img = @ctx.__js_call__("getImageData", [0, 0, 2, 3])
    assert_equal(2, img.__js_get__("width"))
    assert_equal(3, img.__js_get__("height"))
    data = img.__js_get__("data")
    assert_equal(2 * 3 * 4, data.length)
    assert(data.all?(&:zero?))
  end

  def test_create_image_data_by_size_and_by_imagedata
    by_size = @ctx.__js_call__("createImageData", [4, 5])
    assert_equal(4 * 5 * 4, by_size.__js_get__("data").length)

    clone = @ctx.__js_call__("createImageData", [by_size])
    assert_equal(4, clone.__js_get__("width"))
    assert_equal(5, clone.__js_get__("height"))
  end

  # A deserialized clone holds the pixels the page wrote, and its clones keep
  # them; a buffer of another length is not this image's.
  def test_a_clone_holds_the_pixels_it_was_given
    img = @ctx.__js_call__("createImageData", [1, 1])
    img.__js_set__("__dommyPixels", Dommy::Bridge::Bytes.new([1, 2, 3, 4]))
    clone = img.__internal_structured_clone__
    assert_equal([false, true], [img.__js_get__("__dommyClone"), clone.__js_get__("__dommyClone")])
    assert_equal([1, 2, 3, 4], clone.__js_get__("data"))
    assert_equal([1, 2, 3, 4], clone.__js_get__("__dommyPixels").to_a)
    img.__js_set__("__dommyPixels", Dommy::Bridge::Bytes.new([1, 2]))
    assert_equal([0, 0, 0, 0], img.__js_get__("data"))
    assert_nil(@ctx.__js_call__("createImageData", [1, 1]).__js_get__("__dommyPixels"))
  end

  # `new ImageData(sw, sh)` is transparent black; `new ImageData(data, sw [, sh])`
  # takes data's pixels, its height from the length; bad sizes are errors.
  def test_image_data_constructor
    ctor = @doc.default_view.__js_get__("ImageData")
    by_size = ctor.__js_new__([2, 3])
    assert_equal([2, 3, 24], [by_size.width, by_size.height, by_size.__js_get__("data").length])

    pixels = Dommy::Bridge::Bytes.new([200] + [0] * 15)
    from_data = ctor.__js_new__([pixels, 2])
    assert_equal([2, 2, 200], [from_data.width, from_data.height, from_data.__js_get__("data")[0]])
    assert_equal(2, ctor.__js_new__([pixels, 2, 2]).height)

    assert_raises(Dommy::DOMException::IndexSizeError) { ctor.__js_new__([0, 1]) }
    assert_raises(Dommy::DOMException::IndexSizeError) { ctor.__js_new__([pixels, 3]) }
    assert_raises(Dommy::DOMException::IndexSizeError) { ctor.__js_new__([pixels, 2, 3]) }
    assert_raises(Dommy::DOMException::InvalidStateError) { ctor.__js_new__([Dommy::Bridge::Bytes.new([0] * 6), 1]) }
    assert_raises(Dommy::Bridge::TypeError) { ctor.__js_new__([1]) }
  end

  def test_measure_text_reports_a_width
    metrics = @ctx.__js_call__("measureText", ["hello"])
    assert_operator(metrics.__js_get__("width"), :>, 0)
    assert_equal(0, metrics.__js_get__("actualBoundingBoxAscent"))
  end

  def test_gradient_stub_accepts_color_stops
    grad = @ctx.__js_call__("createLinearGradient", [0, 0, 1, 1])
    assert_kind_of(Dommy::CanvasGradient, grad)
    assert_nil(grad.__js_call__("addColorStop", [0, "#fff"]))
  end

  def test_to_data_url_is_a_constant_png
    assert_match(%r{\Adata:image/png;base64,}, @canvas.__js_call__("toDataURL", []))
  end

  def test_canvas_still_has_html_element_behavior
    assert_respond_to(@canvas, :click)
    fired = false
    @canvas.on("click") { fired = true }
    @canvas.click
    assert(fired, "addEventListener/click inherited from HTMLElement still work")
  end
end
