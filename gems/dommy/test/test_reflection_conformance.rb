# frozen_string_literal: true

require_relative "test_helper"

# Reflected IDL attributes and the DOMTokenLists HTML gives elements, held to
# the HTML Standard's own wording (§2.6.1 reflection, the per-element IDL
# prose) where an earlier implementation followed a browser or a guess.
class TestReflectionConformance < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window.document
  end

  def el(name) = @doc.create_element(name)

  # DOM's supports(token): a TypeError without supported tokens, else an
  # ASCII-case-insensitive membership test in them.
  def test_token_list_supports
    assert_raises(Dommy::Bridge::TypeError) { el("div").class_list.supports?("a") }
    assert_raises(Dommy::Bridge::TypeError) { el("link").sizes.supports?("any") }

    assert el("link").rel_list.supports?("STYLESHEET")
    refute el("link").rel_list.supports?("canonical")
    assert el("a").rel_list.supports?("NoOpener")
    refute el("a").rel_list.supports?("stylesheet")
    assert el("area").rel_list.supports?("noreferrer")
    assert el("form").rel_list.supports?("opener")
    assert el("iframe").sandbox.supports?("allow-Scripts")
    refute el("iframe").sandbox.supports?("allow-everything")
  end

  # Assigning a token list first (PutForwards=value) still yields the list
  # with its supported tokens.
  def test_token_list_supports_after_put_forwards
    iframe = el("iframe")
    iframe.sandbox = "allow-forms"
    assert iframe.sandbox.supports?("allow-forms")
    assert_equal "allow-forms", iframe.get_attribute("sandbox")
  end

  def test_blocking_token_lists
    %w[link script style].each do |name|
      element = el(name)
      assert element.blocking.supports?("render"), name
      refute element.blocking.supports?("asdf"), name
      element.blocking = "asdf"
      assert_equal "asdf", element.get_attribute("blocking")
      assert_same element.blocking, element.blocking
    end
  end

  # HyperlinkElementUtils' `hash` is url_hash in Ruby, leaving Object#hash
  # alone so anchors work as Hash keys and with uniq.
  def test_hyperlink_hash_does_not_shadow_object_hash
    a = el("a")
    a.href = "https://example.test/p#frag"
    b = el("a")
    b.href = "https://example.test/p#frag"
    assert_equal "#frag", a.url_hash
    assert_kind_of Integer, a.hash
    assert_equal 2, [a, b, a].uniq.size
    assert_equal 1, { a => 1 }[a]
    a.url_hash = "other"
    assert_equal "https://example.test/p#other", a.get_attribute("href")
    assert_equal "#other", a.__js_get__("hash")
    a.__js_set__("hash", "x")
    assert_equal "#x", el("area").tap { |e| e.href = a.href }.url_hash
  end

  # canvas width/height reflect as unsigned longs with the attributes' own
  # defaults.
  def test_canvas_dimensions
    canvas = el("canvas")
    assert_equal [300, 150], [canvas.width, canvas.height]
    canvas.set_attribute("width", "-1")
    canvas.set_attribute("height", "abc")
    assert_equal [300, 150], [canvas.width, canvas.height]
    canvas.set_attribute("width", " 12px")
    assert_equal 12, canvas.width
    canvas.height = 3_000_000_000
    assert_equal "150", canvas.get_attribute("height")
    canvas.width = 7.9
    assert_equal "7", canvas.get_attribute("width")
  end

  # img width/height setters convert as unsigned long, from JS as from Ruby.
  def test_img_dimension_setters
    img = el("img")
    img.__js_set__("width", 2_147_483_648)
    assert_equal "0", img.get_attribute("width")
    img.__js_set__("height", -0.0)
    assert_equal "0", img.get_attribute("height")
    img.__js_set__("height", 5.5)
    assert_equal "5", img.get_attribute("height")
  end

  def test_img_position_and_fetch_priority
    img = el("img")
    assert_equal [0, 0], [img.__js_get__("x"), img.__js_get__("y")]
    assert_equal "auto", img.fetch_priority
    img.set_attribute("fetchpriority", "LOW")
    assert_equal "low", img.fetch_priority
    img.set_attribute("fetchpriority", "urgent")
    assert_equal "auto", img.fetch_priority
  end

  def test_img_decode
    win = Dommy.parse("<!DOCTYPE html><img id=a><img id=b src=x.png><img id=c src='http://[x'>" \
                      "<img id=d srcset='a.png 1x'><img id=e src='' srcset=' , '>")
    results = %w[a b c d e].to_h do |id|
      [id, win.document.get_element_by_id(id).decode]
    end
    win.scheduler.advance_time(0)
    states = results.transform_values do |promise|
      promise.await
      :fulfilled
    rescue Dommy::DOMException::EncodingError
      :encoding_error
    end
    assert_equal({ "a" => :encoding_error, "b" => :fulfilled, "c" => :encoding_error,
                   "d" => :fulfilled, "e" => :encoding_error }, states)
  end

  def test_script_cross_origin_and_fetch_priority
    script = el("script")
    assert_nil script.crossorigin
    script.set_attribute("crossorigin", "")
    assert_equal "anonymous", script.crossorigin
    script.set_attribute("crossorigin", "USE-CREDENTIALS")
    assert_equal "use-credentials", script.crossorigin
    script.crossorigin = nil
    refute script.has_attribute?("crossorigin")
    assert_equal "auto", script.fetch_priority
    link = el("link")
    link.set_attribute("fetchpriority", "High")
    assert_equal "high", link.fetch_priority
  end

  def test_hyperlink_referrer_policy
    %w[a area].each do |name|
      element = el(name)
      assert_equal "", element.referrer_policy
      element.set_attribute("referrerpolicy", "NO-REFERRER")
      assert_equal "no-referrer", element.referrer_policy
      element.set_attribute("referrerpolicy", "bogus")
      assert_equal "", element.referrer_policy
    end
  end

  def test_template_declarative_shadow_root_attributes
    template = el("template")
    assert_equal "", template.shadow_root_mode
    assert_equal "named", template.shadow_root_slot_assignment
    template.set_attribute("shadowrootmode", "CLOSED")
    template.set_attribute("shadowrootslotassignment", "Manual")
    assert_equal "closed", template.shadow_root_mode
    assert_equal "manual", template.shadow_root_slot_assignment
    template.set_attribute("shadowrootmode", "x")
    template.set_attribute("shadowrootslotassignment", "x")
    assert_equal "", template.shadow_root_mode
    assert_equal "named", template.shadow_root_slot_assignment
    refute template.shadow_root_clonable
    template.shadow_root_delegates_focus = true
    assert_equal "", template.get_attribute("shadowrootdelegatesfocus")
    template.shadow_root_custom_element_registry = "x"
    assert_equal "x", template.get_attribute("shadowrootcustomelementregistry")
  end

  def test_col_span_li_ul_type_media_loading
    col = el("col")
    assert_equal 1, col.span
    col.set_attribute("span", "0")
    assert_equal 1, col.span
    col.set_attribute("span", "5000")
    assert_equal 1000, col.span
    col.span = 7
    assert_equal "7", col.get_attribute("span")
    li = el("li")
    li.type = "disc"
    assert_equal "disc", li.get_attribute("type")
    assert_equal "", el("ul").type
    video = el("video")
    assert_equal "eager", video.loading
    video.set_attribute("loading", "LAZY")
    assert_equal "lazy", video.loading
  end

  def test_js_number_to_string
    to_s = Dommy::Internal::JsNumber.method(:to_string)
    assert_equal "5", to_s.(5.0)
    assert_equal "0", to_s.(-0.0)
    assert_equal "1e+21", to_s.(1e21)
    assert_equal "100000000000000000000", to_s.(1e20)
    assert_equal "1e+25", to_s.(1e25)
    assert_equal "1e-7", to_s.(1e-7)
    assert_equal "0.000001", to_s.(1e-6)
    assert_equal "1.5e-10", to_s.(1.5e-10)
    assert_equal "-123.456", to_s.(-123.456)
    assert_equal "0.30000000000000004", to_s.(0.1 + 0.2)
    assert_equal "5e-324", to_s.(5e-324)
    assert_equal "NaN", to_s.(Float::NAN)
    assert_equal "-Infinity", to_s.(-Float::INFINITY)
  end

  def test_parse_floating_point_number
    parse = Dommy::Internal::ReflectedAttributes.method(:parse_floating_point_number)
    assert_equal 1.5, parse.(" 1.5px")
    assert_equal 0.5, parse.("+.5")
    assert_equal 100.0, parse.("1.e2")
    assert_equal 2.0, parse.("2e")
    assert_equal 1000.0, parse.("1e3x")
    assert_equal 0.0, parse.("0x1A")
    assert_equal 1.0, parse.("1_0")
    assert_equal 0.0, parse.("-0")
    refute parse.("-0").to_s.start_with?("-")
    [nil, "", "-", ".", ".e1", "e1", "\v7", "1e999"].each { |input| assert_nil parse.(input), input.inspect }
  end

  def test_double_reflection_writes_ecmascript_strings
    meter = el("meter")
    meter.value = 1e25
    assert_equal "1e+25", meter.get_attribute("value")
    meter.max = 1e-10
    assert_equal "1e-10", meter.get_attribute("max")
    meter.min = 5.0
    assert_equal "5", meter.get_attribute("min")
  end

  def test_meter_and_progress_parse_with_the_html_rules
    meter = el("meter")
    meter.set_attribute("value", "0.5px")
    assert_equal 0.5, meter.value
    meter.set_attribute("max", "0x10")
    assert_equal 0.0, meter.max # "0x10" is 0 (the rules stop at "x")
    assert_equal 0.0, meter.value # clamped to the maximum
    progress = el("progress")
    assert_equal(-1.0, progress.position)
    progress.set_attribute("max", "\v7")
    assert_equal 1.0, progress.max
    progress.set_attribute("max", " 4e0x")
    assert_equal 4.0, progress.max
    progress.set_attribute("value", "")
    assert_equal 0.0, progress.position # present, so determinate
    progress.set_attribute("value", "2")
    assert_equal 0.5, progress.position
    progress.max = -1
    assert_equal " 4e0x", progress.get_attribute("max")
    progress.max = 8
    assert_equal "8", progress.get_attribute("max")
  end
end
