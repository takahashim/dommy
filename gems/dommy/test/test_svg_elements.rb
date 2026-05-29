# frozen_string_literal: true

require_relative "test_helper"

# Tests the SVG specialized Element classes — dispatch from
# namespace + tag name, snake_case property accessors, and
# camelCase JS-bridge keys.
class TestSVGElements < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <svg viewBox="0 0 100 100" width="200" height="150">
          <g id="shapes">
            <circle cx="50" cy="50" r="40" fill="red"/>
            <rect x="10" y="20" width="80" height="60" rx="5"/>
            <ellipse cx="60" cy="70" rx="20" ry="10"/>
            <line x1="0" y1="0" x2="100" y2="100"/>
            <polygon points="0,0 10,0 10,10"/>
            <polyline points="0,0 5,5 10,0"/>
            <path d="M10,10 L90,90"/>
          </g>
          <text x="10" y="40" text-anchor="middle">Hi<tspan dx="5">there</tspan></text>
          <defs>
            <linearGradient id="lg" x1="0" x2="100" gradientUnits="userSpaceOnUse">
              <stop offset="0%"/>
              <stop offset="100%"/>
            </linearGradient>
            <radialGradient id="rg" cx="50" cy="50" r="50" fx="40" fy="40"/>
            <pattern id="pt" x="0" y="0" width="10" height="10" patternUnits="userSpaceOnUse"/>
            <mask id="mk" maskUnits="userSpaceOnUse"/>
            <clipPath id="cp" clipPathUnits="userSpaceOnUse"/>
            <filter id="ft" x="0" y="0" filterUnits="userSpaceOnUse"/>
            <marker id="mk2" refX="5" refY="5" markerWidth="10" markerHeight="10"/>
            <symbol id="sym" viewBox="0 0 20 20"/>
          </defs>
          <use href="#sym" x="10" y="10" width="20" height="20"/>
          <image href="logo.png" x="5" y="5" width="50" height="50"/>
          <foreignObject x="0" y="0" width="100" height="100"/>
          <title>SVG title</title>
          <desc>SVG description</desc>
        </svg>
      HTML
    )
    @doc = @win.document
  end

  # --- Class dispatch ---------------------------------------------

  def test_svg_root_dispatches_to_svgsvgelement
    assert_kind_of(Dommy::SVGSVGElement, @doc.query_selector("svg"))
  end

  def test_g_dispatches_to_svggelement
    assert_kind_of(Dommy::SVGGElement, @doc.query_selector("g"))
  end

  def test_circle_rect_ellipse_line_dispatch
    assert_kind_of(Dommy::SVGCircleElement, @doc.query_selector("circle"))
    assert_kind_of(Dommy::SVGRectElement, @doc.query_selector("rect"))
    assert_kind_of(Dommy::SVGEllipseElement, @doc.query_selector("ellipse"))
    assert_kind_of(Dommy::SVGLineElement, @doc.query_selector("line"))
  end

  def test_polygon_polyline_path_dispatch
    assert_kind_of(Dommy::SVGPolygonElement, @doc.query_selector("polygon"))
    assert_kind_of(Dommy::SVGPolylineElement, @doc.query_selector("polyline"))
    assert_kind_of(Dommy::SVGPathElement, @doc.query_selector("path"))
  end

  def test_text_tspan_dispatch
    assert_kind_of(Dommy::SVGTextElement, @doc.query_selector("text"))
    assert_kind_of(Dommy::SVGTSpanElement, @doc.query_selector("tspan"))
  end

  def test_gradient_pattern_dispatch
    assert_kind_of(Dommy::SVGLinearGradientElement, @doc.query_selector("linearGradient"))
    assert_kind_of(Dommy::SVGRadialGradientElement, @doc.query_selector("radialGradient"))
    assert_kind_of(Dommy::SVGStopElement, @doc.query_selector("stop"))
    assert_kind_of(Dommy::SVGPatternElement, @doc.query_selector("pattern"))
  end

  def test_filter_marker_mask_clip_dispatch
    assert_kind_of(Dommy::SVGFilterElement, @doc.query_selector("filter"))
    assert_kind_of(Dommy::SVGMarkerElement, @doc.query_selector("marker"))
    assert_kind_of(Dommy::SVGMaskElement, @doc.query_selector("mask"))
    assert_kind_of(Dommy::SVGClipPathElement, @doc.query_selector("clipPath"))
  end

  def test_use_image_foreignobject_symbol_defs_dispatch
    assert_kind_of(Dommy::SVGUseElement, @doc.query_selector("use"))
    assert_kind_of(Dommy::SVGImageElement, @doc.query_selector("image"))
    assert_kind_of(Dommy::SVGForeignObjectElement, @doc.query_selector("foreignObject"))
    assert_kind_of(Dommy::SVGSymbolElement, @doc.query_selector("symbol"))
    assert_kind_of(Dommy::SVGDefsElement, @doc.query_selector("defs"))
  end

  def test_svg_title_is_distinct_from_html_title
    svg_title = @doc.query_selector("svg title")
    assert_kind_of(Dommy::SVGTitleElement, svg_title)
    refute_kind_of(Dommy::HTMLTitleElement, svg_title)
  end

  def test_html_title_in_head_stays_htmltitleelement
    win = make_window("")
    win.document.body.inner_html = ""
    # Inject a <title> into <head>
    head = win.document.query_selector("head") || win.document.body.parent_node
    if head
      head.inner_html = "<title>Page title</title>"
      el = win.document.query_selector("title")
      assert_kind_of(Dommy::HTMLTitleElement, el)
      refute_kind_of(Dommy::SVGTitleElement, el)
    end
  end

  def test_svg_desc_dispatch
    assert_kind_of(Dommy::SVGDescElement, @doc.query_selector("desc"))
  end

  def test_unknown_svg_tag_falls_back_to_svgelement_base
    # Deprecated <glyph> is not in our specialized table — should
    # fall through to the base SVGElement.
    win = make_window("<svg><glyph unicode='A'/></svg>")
    el = win.document.query_selector("glyph")
    assert_instance_of(Dommy::SVGElement, el)
  end

  # --- All SVG elements inherit from SVGElement -------------------

  def test_all_svg_subclasses_are_svgelement
    %w[
      svg
      g
      circle
      rect
      ellipse
      line
      polygon
      polyline
      path
      text
      tspan
      defs
      use
      image
      symbol
      foreignObject
      title
      desc
      mask
      clipPath
      pattern
      linearGradient
      radialGradient
      stop
      filter
      marker
    ]
      .each do |tag|
        el = @doc.query_selector(tag)
        next if el.nil?

        assert_kind_of(Dommy::SVGElement, el, "<#{tag}> should descend from SVGElement")
        assert_kind_of(Dommy::Element, el, "<#{tag}> should descend from Element")
      end
  end

  # --- Attribute reflection (Ruby snake_case) ---------------------

  def test_circle_cx_cy_r_reflection
    circle = @doc.query_selector("circle")
    assert_equal("50", circle.cx)
    assert_equal("50", circle.cy)
    assert_equal("40", circle.r)

    circle.cx = "75"
    assert_equal("75", circle.cx)
    assert_equal("75", circle.get_attribute("cx"))
  end

  def test_rect_box_reflection
    rect = @doc.query_selector("rect")
    assert_equal("10", rect.x)
    assert_equal("20", rect.y)
    assert_equal("80", rect.width)
    assert_equal("60", rect.height)
    assert_equal("5", rect.rx)
  end

  def test_svg_root_view_box_uses_camelcase_attr
    svg = @doc.query_selector("svg")
    # The HTML attribute is "viewBox" (camelCase, SVG case-sensitive).
    assert_equal("0 0 100 100", svg.view_box)
    assert_equal("0 0 100 100", svg.get_attribute("viewBox"))
  end

  def test_line_coords
    line = @doc.query_selector("line")
    assert_equal("0", line.x1)
    assert_equal("0", line.y1)
    assert_equal("100", line.x2)
    assert_equal("100", line.y2)
  end

  def test_polygon_polyline_points
    assert_equal("0,0 10,0 10,10", @doc.query_selector("polygon").points)
    assert_equal("0,0 5,5 10,0", @doc.query_selector("polyline").points)
  end

  def test_path_d
    assert_equal("M10,10 L90,90", @doc.query_selector("path").d)
  end

  def test_text_attrs
    text = @doc.query_selector("text")
    assert_equal("10", text.x)
    assert_equal("40", text.y)
    assert_equal("middle", text.text_anchor)
  end

  def test_linear_gradient_attrs
    lg = @doc.query_selector("linearGradient")
    assert_equal("0", lg.x1)
    assert_equal("100", lg.x2)
    assert_equal("userSpaceOnUse", lg.gradient_units)
  end

  def test_radial_gradient_attrs
    rg = @doc.query_selector("radialGradient")
    assert_equal("50", rg.cx)
    assert_equal("50", rg.cy)
    assert_equal("50", rg.r)
    assert_equal("40", rg.fx)
    assert_equal("40", rg.fy)
  end

  def test_marker_camelcase_attrs
    m = @doc.query_selector("marker")
    assert_equal("5", m.ref_x)
    assert_equal("5", m.ref_y)
    assert_equal("10", m.marker_width)
    assert_equal("10", m.marker_height)
  end

  # --- JS bridge (camelCase keys) ---------------------------------

  def test_svg_root_js_get_camelcase
    svg = @doc.query_selector("svg")
    assert_equal("0 0 100 100", svg.__js_get__("viewBox"))
    assert_equal("200", svg.__js_get__("width"))
  end

  def test_circle_js_get_set_round_trip
    c = @doc.query_selector("circle")
    assert_equal("50", c.__js_get__("cx"))
    c.__js_set__("cx", "99")
    assert_equal("99", c.__js_get__("cx"))
    assert_equal("99", c.cx)
  end

  def test_marker_js_get_uses_camelcase_keys
    m = @doc.query_selector("marker")
    assert_equal("5", m.__js_get__("refX"))
    assert_equal("10", m.__js_get__("markerWidth"))
  end

  def test_linear_gradient_js_set
    lg = @doc.query_selector("linearGradient")
    lg.__js_set__("spreadMethod", "reflect")
    assert_equal("reflect", lg.spread_method)
  end

  # --- createElementNS dispatch -----------------------------------

  def test_create_element_ns_returns_specialized_class
    svg_ns = "http://www.w3.org/2000/svg"
    [
      ["circle", Dommy::SVGCircleElement],
      ["rect", Dommy::SVGRectElement],
      ["path", Dommy::SVGPathElement],
      ["linearGradient", Dommy::SVGLinearGradientElement]
    ].each do |tag, klass|
      el = @doc.create_element_ns(svg_ns, tag)
      assert_kind_of(klass, el, "createElementNS(svg, #{tag.inspect}) should be #{klass}")
    end
  end

  def test_create_element_no_namespace_stays_html
    # no namespace argument
    el = @doc.create_element("circle")
    refute_kind_of(Dommy::SVGCircleElement, el)
  end

  # --- Common SVGElement accessors --------------------------------

  def test_id_via_svgelement_base
    circle = @doc.query_selector("circle")
    circle.id = "main-circle"
    assert_equal("main-circle", circle.id)
    assert_equal("main-circle", circle.__js_get__("id"))
  end

  def test_class_name_via_svgelement_base
    circle = @doc.query_selector("circle")
    circle.class_name = "shape highlighted"
    assert_equal("shape highlighted", circle.class_name)
    assert_equal("shape highlighted", circle.__js_get__("className"))
  end

  # --- Matchers integration (sanity check) ------------------------

  def test_existing_matchers_work_with_svg
    assert(@doc.query_selector("svg circle"))
    assert_equal(1, @doc.query_selector_all("circle").length)
    assert_equal("red", @doc.query_selector("circle").get_attribute("fill"))
  end

  # --- SVG-namespace <a>, textPath, view, switch, metadata --------

  def test_svg_a_is_distinct_from_html_a
    win = make_window("<svg><a href='/x' target='_top'><circle/></a></svg>")
    a = win.document.query_selector("svg a")
    assert_kind_of(Dommy::SVGAElement, a)
    refute_kind_of(Dommy::HTMLAnchorElement, a)
    assert_equal("/x", a.href)
    assert_equal("_top", a.target)
    assert_equal("/x", a.__js_get__("href"))
  end

  def test_html_a_outside_svg_stays_html
    win = make_window("<a href='/y'>link</a>")
    a = win.document.query_selector("a")
    assert_kind_of(Dommy::HTMLAnchorElement, a)
    refute_kind_of(Dommy::SVGAElement, a)
  end

  def test_text_path_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><path id='p' d='M0,0 L100,100'/>
          <text><textPath href='#p' startOffset='10%' method='align' lengthAdjust='spacing'>Hi</textPath></text>
        </svg>
      HTML
    )
    tp = win.document.query_selector("textPath")
    assert_kind_of(Dommy::SVGTextPathElement, tp)
    assert_equal("#p", tp.href)
    assert_equal("10%", tp.start_offset)
    assert_equal("align", tp.method_attr)
    assert_equal("spacing", tp.length_adjust)
    assert_equal("10%", tp.__js_get__("startOffset"))
  end

  def test_view_element
    win = make_window("<svg><view id='v1' viewBox='0 0 50 50' zoomAndPan='disable'/></svg>")
    view = win.document.query_selector("view")
    assert_kind_of(Dommy::SVGViewElement, view)
    assert_equal("0 0 50 50", view.view_box)
    assert_equal("disable", view.zoom_and_pan)
    assert_equal("disable", view.__js_get__("zoomAndPan"))
  end

  def test_switch_element
    win = make_window("<svg><switch><g/><g/></switch></svg>")
    sw = win.document.query_selector("switch")
    assert_kind_of(Dommy::SVGSwitchElement, sw)
  end

  def test_metadata_element
    win = make_window("<svg><metadata><foo>bar</foo></metadata></svg>")
    md = win.document.query_selector("metadata")
    assert_kind_of(Dommy::SVGMetadataElement, md)
  end

  # --- Filter primitives ------------------------------------------

  def test_fegaussianblur_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter id="f">
          <feGaussianBlur in="SourceGraphic" stdDeviation="2" edgeMode="duplicate" result="blur"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feGaussianBlur")
    assert_kind_of(Dommy::SVGFEGaussianBlurElement, fe)
    assert_kind_of(Dommy::SVGFilterPrimitiveElement, fe)
    assert_equal("SourceGraphic", fe.in1)
    assert_equal("2", fe.std_deviation)
    assert_equal("duplicate", fe.edge_mode)
    assert_equal("blur", fe.result)
    assert_equal("2", fe.__js_get__("stdDeviation"))
  end

  def test_feoffset_dispatch_and_attrs
    win = make_window("<svg><filter><feOffset in=\"blur\" dx=\"5\" dy=\"3\" result=\"off\"/></filter></svg>")
    fe = win.document.query_selector("feOffset")
    assert_kind_of(Dommy::SVGFEOffsetElement, fe)
    assert_equal("blur", fe.in1)
    assert_equal("5", fe.dx)
    assert_equal("3", fe.dy)
    assert_equal("off", fe.result)
  end

  def test_feblend_dispatch_and_attrs
    win = make_window("<svg><filter><feBlend in=\"A\" in2=\"B\" mode=\"multiply\"/></filter></svg>")
    fe = win.document.query_selector("feBlend")
    assert_kind_of(Dommy::SVGFEBlendElement, fe)
    assert_equal("A", fe.in1)
    assert_equal("B", fe.in2)
    assert_equal("multiply", fe.mode)
  end

  def test_fecolormatrix_dispatch_and_attrs
    win = make_window("<svg><filter><feColorMatrix in=\"X\" type=\"matrix\" values=\"1 0 0 0 0\"/></filter></svg>")
    fe = win.document.query_selector("feColorMatrix")
    assert_kind_of(Dommy::SVGFEColorMatrixElement, fe)
    assert_equal("X", fe.in1)
    assert_equal("matrix", fe.type)
    assert_equal("1 0 0 0 0", fe.values)
  end

  def test_feflood_dispatch_and_attrs
    win = make_window("<svg><filter><feFlood flood-color=\"red\" flood-opacity=\"0.5\"/></filter></svg>")
    fe = win.document.query_selector("feFlood")
    assert_kind_of(Dommy::SVGFEFloodElement, fe)
    assert_equal("red", fe.flood_color)
    assert_equal("0.5", fe.flood_opacity)
  end

  def test_fecomposite_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feComposite in="A" in2="B" operator="arithmetic" k1="0" k2="1" k3="0" k4="0"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feComposite")
    assert_kind_of(Dommy::SVGFECompositeElement, fe)
    assert_equal("arithmetic", fe.operator)
    assert_equal("1", fe.k2)
  end

  def test_femerge_with_femergenodes
    win = make_window(
      <<~HTML
        <svg><filter>
          <feMerge>
            <feMergeNode in="blur1"/>
            <feMergeNode in="blur2"/>
          </feMerge>
        </filter></svg>
      HTML
    )
    merge = win.document.query_selector("feMerge")
    nodes = win.document.query_selector_all("feMergeNode").to_a
    assert_kind_of(Dommy::SVGFEMergeElement, merge)
    assert_equal(2, nodes.length)
    nodes.each { |n| assert_kind_of(Dommy::SVGFEMergeNodeElement, n) }
    assert_equal("blur1", nodes[0].in1)
    assert_equal("blur2", nodes[1].in1)
  end

  def test_filter_primitive_common_attrs_on_subclass
    win = make_window(
      <<~HTML
        <svg><filter>
          <feGaussianBlur x="0" y="0" width="100" height="100" result="primary"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feGaussianBlur")
    assert_equal("0", fe.x)
    assert_equal("0", fe.y)
    assert_equal("100", fe.width)
    assert_equal("100", fe.height)
    assert_equal("primary", fe.result)
  end

  # (All filter primitives are now specialized; the generic-fallback
  # path is covered by `test_unknown_svg_tag_falls_back_to_svgelement_base`.)

  # --- Color transfer (feComponentTransfer + feFunc{R,G,B,A}) -----

  def test_fecomponenttransfer_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feComponentTransfer in="SourceGraphic" result="ct">
            <feFuncR type="linear" slope="2" intercept="0.5"/>
            <feFuncG type="gamma" amplitude="1" exponent="2" offset="0"/>
            <feFuncB type="table" tableValues="0 0.5 1"/>
            <feFuncA type="identity"/>
          </feComponentTransfer>
        </filter></svg>
      HTML
    )
    ct = win.document.query_selector("feComponentTransfer")
    assert_kind_of(Dommy::SVGFEComponentTransferElement, ct)
    assert_kind_of(Dommy::SVGFilterPrimitiveElement, ct)
    assert_equal("SourceGraphic", ct.in1)
    assert_equal("ct", ct.result)
  end

  def test_fefunc_subclass_dispatch
    win = make_window(
      <<~HTML
        <svg><filter><feComponentTransfer>
          <feFuncR type="linear"/>
          <feFuncG type="linear"/>
          <feFuncB type="linear"/>
          <feFuncA type="linear"/>
        </feComponentTransfer></filter></svg>
      HTML
    )
    assert_kind_of(Dommy::SVGFEFuncRElement, win.document.query_selector("feFuncR"))
    assert_kind_of(Dommy::SVGFEFuncGElement, win.document.query_selector("feFuncG"))
    assert_kind_of(Dommy::SVGFEFuncBElement, win.document.query_selector("feFuncB"))
    assert_kind_of(Dommy::SVGFEFuncAElement, win.document.query_selector("feFuncA"))
  end

  def test_fefunc_all_descend_from_component_transfer_function_base
    win = make_window(
      <<~HTML
        <svg><filter><feComponentTransfer>
          <feFuncR type="linear"/>
          <feFuncG type="linear"/>
        </feComponentTransfer></filter></svg>
      HTML
    )
    %w[feFuncR feFuncG].each do |tag|
      el = win.document.query_selector(tag)
      assert_kind_of(Dommy::SVGComponentTransferFunctionElement, el)
      assert_kind_of(Dommy::SVGElement, el)
    end
  end

  def test_fefuncr_linear_attrs
    win = make_window(
      <<~HTML
        <svg><filter><feComponentTransfer>
          <feFuncR type="linear" slope="2" intercept="0.1"/>
        </feComponentTransfer></filter></svg>
      HTML
    )
    fn = win.document.query_selector("feFuncR")
    assert_equal("linear", fn.type)
    assert_equal("2", fn.slope)
    assert_equal("0.1", fn.intercept)
  end

  def test_fefuncg_gamma_attrs
    win = make_window(
      <<~HTML
        <svg><filter><feComponentTransfer>
          <feFuncG type="gamma" amplitude="1.5" exponent="2.2" offset="0"/>
        </feComponentTransfer></filter></svg>
      HTML
    )
    fn = win.document.query_selector("feFuncG")
    assert_equal("gamma", fn.type)
    assert_equal("1.5", fn.amplitude)
    assert_equal("2.2", fn.exponent)
    assert_equal("0", fn.offset)
  end

  def test_fefuncb_table_attrs
    win = make_window(
      <<~HTML
        <svg><filter><feComponentTransfer>
          <feFuncB type="table" tableValues="0 0.5 1"/>
        </feComponentTransfer></filter></svg>
      HTML
    )
    fn = win.document.query_selector("feFuncB")
    assert_equal("table", fn.type)
    assert_equal("0 0.5 1", fn.table_values)
    assert_equal("0 0.5 1", fn.__js_get__("tableValues"))
  end

  def test_fefunc_round_trip_setter
    win = make_window(
      "<svg><filter><feComponentTransfer><feFuncR type=\"identity\"/></feComponentTransfer></filter></svg>"
    )
    fn = win.document.query_selector("feFuncR")
    fn.type = "gamma"
    fn.amplitude = "1.2"
    assert_equal("gamma", fn.type)
    assert_equal("1.2", fn.amplitude)
    assert_equal("1.2", fn.__js_get__("amplitude"))
  end

  # --- Additional filter primitives (Pack C) -----------------------

  def test_fetile_dispatch_and_attrs
    win = make_window("<svg><filter><feTile in=\"SourceGraphic\" result=\"tiled\"/></filter></svg>")
    fe = win.document.query_selector("feTile")
    assert_kind_of(Dommy::SVGFETileElement, fe)
    assert_kind_of(Dommy::SVGFilterPrimitiveElement, fe)
    assert_equal("SourceGraphic", fe.in1)
    assert_equal("tiled", fe.result)
  end

  def test_femorphology_dispatch_and_attrs
    win = make_window("<svg><filter><feMorphology in=\"src\" operator=\"dilate\" radius=\"2\"/></filter></svg>")
    fe = win.document.query_selector("feMorphology")
    assert_kind_of(Dommy::SVGFEMorphologyElement, fe)
    assert_equal("src", fe.in1)
    assert_equal("dilate", fe.operator)
    assert_equal("2", fe.radius)
  end

  def test_feimage_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feImage href="logo.png" preserveAspectRatio="xMidYMid" crossorigin="anonymous"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feImage")
    assert_kind_of(Dommy::SVGFEImageElement, fe)
    assert_equal("logo.png", fe.href)
    assert_equal("xMidYMid", fe.preserve_aspect_ratio)
    assert_equal("anonymous", fe.crossorigin)
  end

  def test_fedropshadow_dispatch_and_attrs
    # NOTE: <feDropShadow> is an SVG 2 addition not in Nokogiri::HTML5's
    # SVG element adjustment table, so its tag is preserved as
    # lowercase rather than the spec-cased "feDropShadow". Dispatch
    # still works via the lowercased SVG_ELEMENT_CLASSES key, but
    # querySelector must use the lowercased name.
    win = make_window(
      <<~HTML
        <svg><filter>
          <feDropShadow in="SourceGraphic" dx="3" dy="3" stdDeviation="2"
                        flood-color="black" flood-opacity="0.5"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("fedropshadow")
    assert_kind_of(Dommy::SVGFEDropShadowElement, fe)
    assert_equal("SourceGraphic", fe.in1)
    assert_equal("3", fe.dx)
    assert_equal("3", fe.dy)
    assert_equal("2", fe.std_deviation)
    assert_equal("black", fe.flood_color)
    assert_equal("0.5", fe.flood_opacity)
    assert_equal("2", fe.__js_get__("stdDeviation"))
  end

  def test_feturbulence_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feTurbulence baseFrequency="0.1" numOctaves="4" seed="42"
                        stitchTiles="stitch" type="turbulence"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feTurbulence")
    assert_kind_of(Dommy::SVGFETurbulenceElement, fe)
    assert_equal("0.1", fe.base_frequency)
    assert_equal("4", fe.num_octaves)
    assert_equal("42", fe.seed)
    assert_equal("stitch", fe.stitch_tiles)
    assert_equal("turbulence", fe.type)
    assert_equal("0.1", fe.__js_get__("baseFrequency"))
  end

  def test_fedisplacementmap_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feDisplacementMap in="A" in2="B" scale="10" xChannelSelector="R" yChannelSelector="G"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feDisplacementMap")
    assert_kind_of(Dommy::SVGFEDisplacementMapElement, fe)
    assert_equal("A", fe.in1)
    assert_equal("B", fe.in2)
    assert_equal("10", fe.scale)
    assert_equal("R", fe.x_channel_selector)
    assert_equal("G", fe.y_channel_selector)
    assert_equal("R", fe.__js_get__("xChannelSelector"))
  end

  def test_fedistantlight_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feDiffuseLighting>
            <feDistantLight azimuth="45" elevation="30"/>
          </feDiffuseLighting>
        </filter></svg>
      HTML
    )
    light = win.document.query_selector("feDistantLight")
    assert_kind_of(Dommy::SVGFEDistantLightElement, light)
    # Light sources are NOT filter primitives — they're plain SVGElements.
    refute_kind_of(Dommy::SVGFilterPrimitiveElement, light)
    assert_equal("45", light.azimuth)
    assert_equal("30", light.elevation)
  end

  def test_fepointlight_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feDiffuseLighting>
            <fePointLight x="10" y="20" z="100"/>
          </feDiffuseLighting>
        </filter></svg>
      HTML
    )
    light = win.document.query_selector("fePointLight")
    assert_kind_of(Dommy::SVGFEPointLightElement, light)
    assert_equal("10", light.x)
    assert_equal("20", light.y)
    assert_equal("100", light.z)
  end

  # --- SMIL animation ----------------------------------------------

  def test_animate_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><circle>
          <animate attributeName="cx" from="0" to="100" dur="2s" begin="0s" fill="freeze"/>
        </circle></svg>
      HTML
    )
    a = win.document.query_selector("animate")
    assert_kind_of(Dommy::SVGAnimateElement, a)
    assert_kind_of(Dommy::SVGAnimationElement, a)
    assert_equal("cx", a.attribute_name)
    assert_equal("0", a.from)
    assert_equal("100", a.to)
    assert_equal("2s", a.dur)
    assert_equal("0s", a.begin)
    assert_equal("freeze", a.fill)
  end

  def test_animate_values_and_calc_mode
    win = make_window(
      <<~HTML
        <svg><circle><animate attributeName="r" values="10;20;10" calcMode="linear" keyTimes="0;0.5;1"/></circle></svg>
      HTML
    )
    a = win.document.query_selector("animate")
    assert_equal("10;20;10", a.values)
    assert_equal("linear", a.calc_mode)
    assert_equal("0;0.5;1", a.key_times)
  end

  def test_animate_transform_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><g>
          <animateTransform attributeName="transform" type="rotate" from="0" to="360" dur="3s" repeatCount="indefinite"/>
        </g></svg>
      HTML
    )
    at = win.document.query_selector("animateTransform")
    assert_kind_of(Dommy::SVGAnimateTransformElement, at)
    assert_equal("rotate", at.type)
    assert_equal("0", at.from)
    assert_equal("360", at.to)
    assert_equal("3s", at.dur)
    assert_equal("indefinite", at.repeat_count)
  end

  def test_animate_motion_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><circle>
          <animateMotion path="M0,0 L100,100" dur="2s" rotate="auto" keyPoints="0;1"/>
        </circle></svg>
      HTML
    )
    am = win.document.query_selector("animateMotion")
    assert_kind_of(Dommy::SVGAnimateMotionElement, am)
    assert_equal("M0,0 L100,100", am.path)
    assert_equal("auto", am.rotate)
    assert_equal("0;1", am.key_points)
  end

  def test_set_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><rect><set attributeName="fill" to="red" begin="click"/></rect></svg>
      HTML
    )
    s = win.document.query_selector("set")
    assert_kind_of(Dommy::SVGSetElement, s)
    assert_equal("fill", s.attribute_name)
    assert_equal("red", s.to)
    assert_equal("click", s.begin)
  end

  def test_mpath_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><path id="p" d="M0,0 L100,100"/>
          <circle><animateMotion><mpath href="#p"/></animateMotion></circle>
        </svg>
      HTML
    )
    mp = win.document.query_selector("mpath")
    assert_kind_of(Dommy::SVGMPathElement, mp)
    assert_equal("#p", mp.href)
  end

  def test_discard_dispatch_and_attrs
    win = make_window("<svg><rect><discard begin=\"5s\" href=\"#target\"/></rect></svg>")
    d = win.document.query_selector("discard")
    assert_kind_of(Dommy::SVGDiscardElement, d)
    assert_equal("5s", d.begin)
    assert_equal("#target", d.href)
  end

  def test_animation_js_bridge_uses_camelcase
    win = make_window("<svg><animate attributeName=\"cx\" repeatCount=\"3\" repeatDur=\"6s\"/></svg>")
    a = win.document.query_selector("animate")
    assert_equal("cx", a.__js_get__("attributeName"))
    assert_equal("3", a.__js_get__("repeatCount"))
    assert_equal("6s", a.__js_get__("repeatDur"))

    a.__js_set__("repeatCount", "indefinite")
    assert_equal("indefinite", a.repeat_count)
  end

  def test_begin_end_round_trip
    win = make_window("<svg><animate begin=\"0s\" end=\"5s\" dur=\"1s\"/></svg>")
    a = win.document.query_selector("animate")
    assert_equal("0s", a.begin)
    assert_equal("5s", a.end)

    a.begin = "click"
    a.end = "10s"
    assert_equal("click", a.begin)
    assert_equal("10s", a.end)
  end

  # --- Remaining filter primitives (lighting + convolve + spot) ----

  def test_fespotlight_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feSpecularLighting>
            <feSpotLight x="0" y="0" z="50" pointsAtX="100" pointsAtY="100" pointsAtZ="0"
                         specularExponent="10" limitingConeAngle="30"/>
          </feSpecularLighting>
        </filter></svg>
      HTML
    )
    light = win.document.query_selector("feSpotLight")
    assert_kind_of(Dommy::SVGFESpotLightElement, light)
    assert_equal("0", light.x)
    assert_equal("100", light.points_at_x)
    assert_equal("100", light.points_at_y)
    assert_equal("0", light.points_at_z)
    assert_equal("10", light.specular_exponent)
    assert_equal("30", light.limiting_cone_angle)
    assert_equal("100", light.__js_get__("pointsAtX"))
  end

  def test_feconvolvematrix_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feConvolveMatrix in="SourceGraphic" order="3" kernelMatrix="0 1 0 1 1 1 0 1 0"
                            divisor="5" bias="0" targetX="1" targetY="1" edgeMode="duplicate"
                            kernelUnitLength="1" preserveAlpha="false"/>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feConvolveMatrix")
    assert_kind_of(Dommy::SVGFEConvolveMatrixElement, fe)
    assert_kind_of(Dommy::SVGFilterPrimitiveElement, fe)
    assert_equal("SourceGraphic", fe.in1)
    assert_equal("3", fe.order)
    assert_equal("0 1 0 1 1 1 0 1 0", fe.kernel_matrix)
    assert_equal("5", fe.divisor)
    assert_equal("0", fe.bias)
    assert_equal("1", fe.target_x)
    assert_equal("1", fe.target_y)
    assert_equal("duplicate", fe.edge_mode)
    assert_equal("1", fe.kernel_unit_length)
    assert_equal("false", fe.preserve_alpha)
    assert_equal("0 1 0 1 1 1 0 1 0", fe.__js_get__("kernelMatrix"))
  end

  def test_fediffuselighting_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feDiffuseLighting in="bump" surfaceScale="5" diffuseConstant="1"
                             kernelUnitLength="1" lighting-color="white">
            <feDistantLight azimuth="45" elevation="30"/>
          </feDiffuseLighting>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feDiffuseLighting")
    assert_kind_of(Dommy::SVGFEDiffuseLightingElement, fe)
    assert_kind_of(Dommy::SVGFilterPrimitiveElement, fe)
    assert_equal("bump", fe.in1)
    assert_equal("5", fe.surface_scale)
    assert_equal("1", fe.diffuse_constant)
    assert_equal("1", fe.kernel_unit_length)
    assert_equal("white", fe.lighting_color)
    assert_equal("5", fe.__js_get__("surfaceScale"))
  end

  def test_fespecularlighting_dispatch_and_attrs
    win = make_window(
      <<~HTML
        <svg><filter>
          <feSpecularLighting in="bump" surfaceScale="5" specularConstant="1.2"
                              specularExponent="20" kernelUnitLength="1" lighting-color="yellow">
            <fePointLight x="50" y="50" z="100"/>
          </feSpecularLighting>
        </filter></svg>
      HTML
    )
    fe = win.document.query_selector("feSpecularLighting")
    assert_kind_of(Dommy::SVGFESpecularLightingElement, fe)
    assert_equal("bump", fe.in1)
    assert_equal("5", fe.surface_scale)
    assert_equal("1.2", fe.specular_constant)
    assert_equal("20", fe.specular_exponent)
    assert_equal("1", fe.kernel_unit_length)
    assert_equal("yellow", fe.lighting_color)
    assert_equal("1.2", fe.__js_get__("specularConstant"))
  end
end
