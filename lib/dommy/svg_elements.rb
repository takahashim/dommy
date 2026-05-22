# frozen_string_literal: true

module Dommy
  # Base for specialized SVGElement subclasses. Mirrors HTMLElement's
  # role for HTML: a thin layer over Element that adds reflection
  # helpers (via Internal::ReflectedAttributes) and a few attribute
  # accessors that apply to every SVG element.
  #
  # Ruby property names use snake_case; the JS bridge (`__js_get__` /
  # `__js_set__`) accepts the camelCase / spec name. The underlying
  # HTML attribute name is whatever the SVG spec defines (often
  # camelCase: `viewBox`, `gradientUnits`, `preserveAspectRatio`),
  # passed verbatim to `reflected_string`.
  class SVGElement < Element
    include Internal::ReflectedAttributes

    # SVG attribute names are case-sensitive (`viewBox` ≠ `viewbox`).
    # Element's get/set/has/remove_attribute consult this flag to
    # decide whether to lowercase the attribute name.
    def case_sensitive_attribute_names?
      true
    end

    # Common SVG attributes shared across all elements.

    def id
      reflected_string("id")
    end

    def id=(value)
      set_reflected_string("id", value)
    end

    def class_name
      reflected_string("class")
    end

    def class_name=(value)
      set_reflected_string("class", value)
    end

    def tabindex
      reflected_string("tabindex")
    end

    def tabindex=(value)
      set_reflected_string("tabindex", value)
    end

    def __js_get__(key)
      case key
      when "id"
        id
      when "className"
        class_name
      when "tabIndex"
        tabindex
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "id"
        self.id = value
      when "className"
        self.class_name = value
      when "tabIndex"
        self.tabindex = value
      else
        super
      end
    end
  end

  # `<svg>` — the root of an SVG subtree.
  class SVGSVGElement < SVGElement
    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def view_box
      reflected_string("viewBox")
    end

    def view_box=(v)
      set_reflected_string("viewBox", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "viewBox"
        view_box
      when "preserveAspectRatio"
        preserve_aspect_ratio
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "viewBox"
        self.view_box = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      else
        super
      end
    end
  end

  # `<g>` — generic group; only inherits common attributes.
  class SVGGElement < SVGElement
  end

  # `<circle>` — cx, cy, r.
  class SVGCircleElement < SVGElement
    def cx
      reflected_string("cx")
    end

    def cx=(v)
      set_reflected_string("cx", v)
    end

    def cy
      reflected_string("cy")
    end

    def cy=(v)
      set_reflected_string("cy", v)
    end

    def r
      reflected_string("r")
    end

    def r=(v)
      set_reflected_string("r", v)
    end

    def __js_get__(key)
      case key
      when "cx"
        cx
      when "cy"
        cy
      when "r"
        r
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "cx"
        self.cx = value
      when "cy"
        self.cy = value
      when "r"
        self.r = value
      else
        super
      end
    end
  end

  # `<rect>` — x, y, width, height, rx, ry.
  class SVGRectElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def rx
      reflected_string("rx")
    end

    def rx=(v)
      set_reflected_string("rx", v)
    end

    def ry
      reflected_string("ry")
    end

    def ry=(v)
      set_reflected_string("ry", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "rx"
        rx
      when "ry"
        ry
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "rx"
        self.rx = value
      when "ry"
        self.ry = value
      else
        super
      end
    end
  end

  # `<ellipse>` — cx, cy, rx, ry.
  class SVGEllipseElement < SVGElement
    def cx
      reflected_string("cx")
    end

    def cx=(v)
      set_reflected_string("cx", v)
    end

    def cy
      reflected_string("cy")
    end

    def cy=(v)
      set_reflected_string("cy", v)
    end

    def rx
      reflected_string("rx")
    end

    def rx=(v)
      set_reflected_string("rx", v)
    end

    def ry
      reflected_string("ry")
    end

    def ry=(v)
      set_reflected_string("ry", v)
    end

    def __js_get__(key)
      case key
      when "cx"
        cx
      when "cy"
        cy
      when "rx"
        rx
      when "ry"
        ry
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "cx"
        self.cx = value
      when "cy"
        self.cy = value
      when "rx"
        self.rx = value
      when "ry"
        self.ry = value
      else
        super
      end
    end
  end

  # `<line>` — x1, y1, x2, y2.
  class SVGLineElement < SVGElement
    def x1
      reflected_string("x1")
    end

    def x1=(v)
      set_reflected_string("x1", v)
    end

    def y1
      reflected_string("y1")
    end

    def y1=(v)
      set_reflected_string("y1", v)
    end

    def x2
      reflected_string("x2")
    end

    def x2=(v)
      set_reflected_string("x2", v)
    end

    def y2
      reflected_string("y2")
    end

    def y2=(v)
      set_reflected_string("y2", v)
    end

    def __js_get__(key)
      case key
      when "x1"
        x1
      when "y1"
        y1
      when "x2"
        x2
      when "y2"
        y2
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x1"
        self.x1 = value
      when "y1"
        self.y1 = value
      when "x2"
        self.x2 = value
      when "y2"
        self.y2 = value
      else
        super
      end
    end
  end

  # `<polygon>` — points (a string like "0,0 10,0 10,10").
  class SVGPolygonElement < SVGElement
    def points
      reflected_string("points")
    end

    def points=(v)
      set_reflected_string("points", v)
    end

    def __js_get__(key)
      key == "points" ? points : super
    end

    def __js_set__(key, value)
      key == "points" ? (self.points = value) : super
    end
  end

  # `<polyline>` — points.
  class SVGPolylineElement < SVGElement
    def points
      reflected_string("points")
    end

    def points=(v)
      set_reflected_string("points", v)
    end

    def __js_get__(key)
      key == "points" ? points : super
    end

    def __js_set__(key, value)
      key == "points" ? (self.points = value) : super
    end
  end

  # `<path>` — d (path data), pathLength.
  class SVGPathElement < SVGElement
    def d
      reflected_string("d")
    end

    def d=(v)
      set_reflected_string("d", v)
    end

    def path_length
      reflected_string("pathLength")
    end

    def path_length=(v)
      set_reflected_string("pathLength", v)
    end

    def __js_get__(key)
      case key
      when "d"
        d
      when "pathLength"
        path_length
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "d"
        self.d = value
      when "pathLength"
        self.path_length = value
      else
        super
      end
    end
  end

  # `<text>` — x, y, dx, dy, text-anchor.
  class SVGTextElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def dx
      reflected_string("dx")
    end

    def dx=(v)
      set_reflected_string("dx", v)
    end

    def dy
      reflected_string("dy")
    end

    def dy=(v)
      set_reflected_string("dy", v)
    end

    def text_anchor
      reflected_string("text-anchor")
    end

    def text_anchor=(v)
      set_reflected_string("text-anchor", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "dx"
        dx
      when "dy"
        dy
      when "textAnchor"
        text_anchor
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "dx"
        self.dx = value
      when "dy"
        self.dy = value
      when "textAnchor"
        self.text_anchor = value
      else
        super
      end
    end
  end

  # `<tspan>` — same coord attrs as <text>.
  class SVGTSpanElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def dx
      reflected_string("dx")
    end

    def dx=(v)
      set_reflected_string("dx", v)
    end

    def dy
      reflected_string("dy")
    end

    def dy=(v)
      set_reflected_string("dy", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "dx"
        dx
      when "dy"
        dy
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "dx"
        self.dx = value
      when "dy"
        self.dy = value
      else
        super
      end
    end
  end

  # `<defs>` — container for reusable definitions; no special attrs.
  class SVGDefsElement < SVGElement
  end

  # `<use>` — href, x, y, width, height.
  class SVGUseElement < SVGElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  # `<image>` — href + box + preserveAspectRatio.
  class SVGImageElement < SVGElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "preserveAspectRatio"
        preserve_aspect_ratio
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      else
        super
      end
    end
  end

  # `<symbol>` — reusable template; viewBox + preserveAspectRatio.
  class SVGSymbolElement < SVGElement
    def view_box
      reflected_string("viewBox")
    end

    def view_box=(v)
      set_reflected_string("viewBox", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def __js_get__(key)
      case key
      when "viewBox"
        view_box
      when "preserveAspectRatio"
        preserve_aspect_ratio
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "viewBox"
        self.view_box = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      else
        super
      end
    end
  end

  # `<foreignObject>` — embeds non-SVG content; standard box attrs.
  class SVGForeignObjectElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  # `<title>` (inside SVG) — distinct from HTMLTitleElement.
  class SVGTitleElement < SVGElement
  end

  # `<desc>` — accessibility description.
  class SVGDescElement < SVGElement
  end

  # `<mask>` — alpha mask region.
  class SVGMaskElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def mask_units
      reflected_string("maskUnits")
    end

    def mask_units=(v)
      set_reflected_string("maskUnits", v)
    end

    def mask_content_units
      reflected_string("maskContentUnits")
    end

    def mask_content_units=(v)
      set_reflected_string("maskContentUnits", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "maskUnits"
        mask_units
      when "maskContentUnits"
        mask_content_units
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "maskUnits"
        self.mask_units = value
      when "maskContentUnits"
        self.mask_content_units = value
      else
        super
      end
    end
  end

  # `<clipPath>` — clipping region.
  class SVGClipPathElement < SVGElement
    def clip_path_units
      reflected_string("clipPathUnits")
    end

    def clip_path_units=(v)
      set_reflected_string("clipPathUnits", v)
    end

    def __js_get__(key)
      key == "clipPathUnits" ? clip_path_units : super
    end

    def __js_set__(key, value)
      key == "clipPathUnits" ? (self.clip_path_units = value) : super
    end
  end

  # `<pattern>` — tile-based paint server.
  class SVGPatternElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def pattern_units
      reflected_string("patternUnits")
    end

    def pattern_units=(v)
      set_reflected_string("patternUnits", v)
    end

    def pattern_content_units
      reflected_string("patternContentUnits")
    end

    def pattern_content_units=(v)
      set_reflected_string("patternContentUnits", v)
    end

    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "patternUnits"
        pattern_units
      when "patternContentUnits"
        pattern_content_units
      when "href"
        href
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "patternUnits"
        self.pattern_units = value
      when "patternContentUnits"
        self.pattern_content_units = value
      when "href"
        self.href = value
      else
        super
      end
    end
  end

  # `<linearGradient>` — linear color gradient paint server.
  class SVGLinearGradientElement < SVGElement
    def x1
      reflected_string("x1")
    end

    def x1=(v)
      set_reflected_string("x1", v)
    end

    def y1
      reflected_string("y1")
    end

    def y1=(v)
      set_reflected_string("y1", v)
    end

    def x2
      reflected_string("x2")
    end

    def x2=(v)
      set_reflected_string("x2", v)
    end

    def y2
      reflected_string("y2")
    end

    def y2=(v)
      set_reflected_string("y2", v)
    end

    def gradient_units
      reflected_string("gradientUnits")
    end

    def gradient_units=(v)
      set_reflected_string("gradientUnits", v)
    end

    def gradient_transform
      reflected_string("gradientTransform")
    end

    def gradient_transform=(v)
      set_reflected_string("gradientTransform", v)
    end

    def spread_method
      reflected_string("spreadMethod")
    end

    def spread_method=(v)
      set_reflected_string("spreadMethod", v)
    end

    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      case key
      when "x1"
        x1
      when "y1"
        y1
      when "x2"
        x2
      when "y2"
        y2
      when "gradientUnits"
        gradient_units
      when "gradientTransform"
        gradient_transform
      when "spreadMethod"
        spread_method
      when "href"
        href
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x1"
        self.x1 = value
      when "y1"
        self.y1 = value
      when "x2"
        self.x2 = value
      when "y2"
        self.y2 = value
      when "gradientUnits"
        self.gradient_units = value
      when "gradientTransform"
        self.gradient_transform = value
      when "spreadMethod"
        self.spread_method = value
      when "href"
        self.href = value
      else
        super
      end
    end
  end

  # `<radialGradient>` — radial color gradient paint server.
  class SVGRadialGradientElement < SVGElement
    def cx
      reflected_string("cx")
    end

    def cx=(v)
      set_reflected_string("cx", v)
    end

    def cy
      reflected_string("cy")
    end

    def cy=(v)
      set_reflected_string("cy", v)
    end

    def r
      reflected_string("r")
    end

    def r=(v)
      set_reflected_string("r", v)
    end

    def fx
      reflected_string("fx")
    end

    def fx=(v)
      set_reflected_string("fx", v)
    end

    def fy
      reflected_string("fy")
    end

    def fy=(v)
      set_reflected_string("fy", v)
    end

    def fr
      reflected_string("fr")
    end

    def fr=(v)
      set_reflected_string("fr", v)
    end

    def gradient_units
      reflected_string("gradientUnits")
    end

    def gradient_units=(v)
      set_reflected_string("gradientUnits", v)
    end

    def gradient_transform
      reflected_string("gradientTransform")
    end

    def gradient_transform=(v)
      set_reflected_string("gradientTransform", v)
    end

    def spread_method
      reflected_string("spreadMethod")
    end

    def spread_method=(v)
      set_reflected_string("spreadMethod", v)
    end

    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      case key
      when "cx"
        cx
      when "cy"
        cy
      when "r"
        r
      when "fx"
        fx
      when "fy"
        fy
      when "fr"
        fr
      when "gradientUnits"
        gradient_units
      when "gradientTransform"
        gradient_transform
      when "spreadMethod"
        spread_method
      when "href"
        href
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "cx"
        self.cx = value
      when "cy"
        self.cy = value
      when "r"
        self.r = value
      when "fx"
        self.fx = value
      when "fy"
        self.fy = value
      when "fr"
        self.fr = value
      when "gradientUnits"
        self.gradient_units = value
      when "gradientTransform"
        self.gradient_transform = value
      when "spreadMethod"
        self.spread_method = value
      when "href"
        self.href = value
      else
        super
      end
    end
  end

  # `<stop>` — a single gradient color stop.
  class SVGStopElement < SVGElement
    def offset
      reflected_string("offset")
    end

    def offset=(v)
      set_reflected_string("offset", v)
    end

    def __js_get__(key)
      key == "offset" ? offset : super
    end

    def __js_set__(key, value)
      key == "offset" ? (self.offset = value) : super
    end
  end

  # `<filter>` — filter region + primitive units + href.
  class SVGFilterElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def filter_units
      reflected_string("filterUnits")
    end

    def filter_units=(v)
      set_reflected_string("filterUnits", v)
    end

    def primitive_units
      reflected_string("primitiveUnits")
    end

    def primitive_units=(v)
      set_reflected_string("primitiveUnits", v)
    end

    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "filterUnits"
        filter_units
      when "primitiveUnits"
        primitive_units
      when "href"
        href
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "filterUnits"
        self.filter_units = value
      when "primitiveUnits"
        self.primitive_units = value
      when "href"
        self.href = value
      else
        super
      end
    end
  end

  # `<marker>` — arrowhead / line marker.
  class SVGMarkerElement < SVGElement
    def ref_x
      reflected_string("refX")
    end

    def ref_x=(v)
      set_reflected_string("refX", v)
    end

    def ref_y
      reflected_string("refY")
    end

    def ref_y=(v)
      set_reflected_string("refY", v)
    end

    def marker_width
      reflected_string("markerWidth")
    end

    def marker_width=(v)
      set_reflected_string("markerWidth", v)
    end

    def marker_height
      reflected_string("markerHeight")
    end

    def marker_height=(v)
      set_reflected_string("markerHeight", v)
    end

    def orient
      reflected_string("orient")
    end

    def orient=(v)
      set_reflected_string("orient", v)
    end

    def marker_units
      reflected_string("markerUnits")
    end

    def marker_units=(v)
      set_reflected_string("markerUnits", v)
    end

    def view_box
      reflected_string("viewBox")
    end

    def view_box=(v)
      set_reflected_string("viewBox", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def __js_get__(key)
      case key
      when "refX"
        ref_x
      when "refY"
        ref_y
      when "markerWidth"
        marker_width
      when "markerHeight"
        marker_height
      when "orient"
        orient
      when "markerUnits"
        marker_units
      when "viewBox"
        view_box
      when "preserveAspectRatio"
        preserve_aspect_ratio
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "refX"
        self.ref_x = value
      when "refY"
        self.ref_y = value
      when "markerWidth"
        self.marker_width = value
      when "markerHeight"
        self.marker_height = value
      when "orient"
        self.orient = value
      when "markerUnits"
        self.marker_units = value
      when "viewBox"
        self.view_box = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      else
        super
      end
    end
  end

  # `<a>` (in the SVG namespace) — a hyperlink wrapping SVG content.
  # Distinct from `HTMLAnchorElement` (the HTML `<a>`).
  class SVGAElement < SVGElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def target
      reflected_string("target")
    end

    def target=(v)
      set_reflected_string("target", v)
    end

    def download
      reflected_string("download")
    end

    def download=(v)
      set_reflected_string("download", v)
    end

    def rel
      reflected_string("rel")
    end

    def rel=(v)
      set_reflected_string("rel", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "target"
        target
      when "download"
        download
      when "rel"
        rel
      when "type"
        type
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "target"
        self.target = value
      when "download"
        self.download = value
      when "rel"
        self.rel = value
      when "type"
        self.type = value
      else
        super
      end
    end
  end

  # `<textPath>` — text laid out along a path.
  class SVGTextPathElement < SVGElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def start_offset
      reflected_string("startOffset")
    end

    def start_offset=(v)
      set_reflected_string("startOffset", v)
    end

    def method_attr
      reflected_string("method")
    end

    def method_attr=(v)
      set_reflected_string("method", v)
    end

    def spacing
      reflected_string("spacing")
    end

    def spacing=(v)
      set_reflected_string("spacing", v)
    end

    def text_length
      reflected_string("textLength")
    end

    def text_length=(v)
      set_reflected_string("textLength", v)
    end

    def length_adjust
      reflected_string("lengthAdjust")
    end

    def length_adjust=(v)
      set_reflected_string("lengthAdjust", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "startOffset"
        start_offset
      when "method"
        method_attr
      when "spacing"
        spacing
      when "textLength"
        text_length
      when "lengthAdjust"
        length_adjust
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "startOffset"
        self.start_offset = value
      when "method"
        self.method_attr = value
      when "spacing"
        self.spacing = value
      when "textLength"
        self.text_length = value
      when "lengthAdjust"
        self.length_adjust = value
      else
        super
      end
    end
  end

  # `<view>` — a named view region referenced by SVG fragment identifier.
  class SVGViewElement < SVGElement
    def view_box
      reflected_string("viewBox")
    end

    def view_box=(v)
      set_reflected_string("viewBox", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def zoom_and_pan
      reflected_string("zoomAndPan")
    end

    def zoom_and_pan=(v)
      set_reflected_string("zoomAndPan", v)
    end

    def __js_get__(key)
      case key
      when "viewBox"
        view_box
      when "preserveAspectRatio"
        preserve_aspect_ratio
      when "zoomAndPan"
        zoom_and_pan
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "viewBox"
        self.view_box = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      when "zoomAndPan"
        self.zoom_and_pan = value
      else
        super
      end
    end
  end

  # `<switch>` — conditionally renders the first child whose feature /
  # systemLanguage attributes match. No special own attributes.
  class SVGSwitchElement < SVGElement
  end

  # `<metadata>` — XML metadata container; opaque to dommy.
  class SVGMetadataElement < SVGElement
  end

  # ===== Filter primitives =====
  #
  # `<filter>`'s children. All inherit the standard region attrs
  # (x / y / width / height) plus `result` (the name of this
  # primitive's output, referenced by subsequent primitives via `in`).
  # Specific primitives add their own attributes.
  class SVGFilterPrimitiveElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def width
      reflected_string("width")
    end

    def width=(v)
      set_reflected_string("width", v)
    end

    def height
      reflected_string("height")
    end

    def height=(v)
      set_reflected_string("height", v)
    end

    def result
      reflected_string("result")
    end

    def result=(v)
      set_reflected_string("result", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "width"
        width
      when "height"
        height
      when "result"
        result
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "result"
        self.result = value
      else
        super
      end
    end
  end

  # `<feGaussianBlur>` — Gaussian blur primitive.
  class SVGFEGaussianBlurElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def std_deviation
      reflected_string("stdDeviation")
    end

    def std_deviation=(v)
      set_reflected_string("stdDeviation", v)
    end

    def edge_mode
      reflected_string("edgeMode")
    end

    def edge_mode=(v)
      set_reflected_string("edgeMode", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "stdDeviation"
        std_deviation
      when "edgeMode"
        edge_mode
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "stdDeviation"
        self.std_deviation = value
      when "edgeMode"
        self.edge_mode = value
      else
        super
      end
    end
  end

  # `<feOffset>` — translates input by (dx, dy).
  class SVGFEOffsetElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def dx
      reflected_string("dx")
    end

    def dx=(v)
      set_reflected_string("dx", v)
    end

    def dy
      reflected_string("dy")
    end

    def dy=(v)
      set_reflected_string("dy", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "dx"
        dx
      when "dy"
        dy
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "dx"
        self.dx = value
      when "dy"
        self.dy = value
      else
        super
      end
    end
  end

  # `<feBlend>` — blends two inputs with a mode.
  class SVGFEBlendElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def in2
      reflected_string("in2")
    end

    def in2=(v)
      set_reflected_string("in2", v)
    end

    def mode
      reflected_string("mode")
    end

    def mode=(v)
      set_reflected_string("mode", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "in2"
        in2
      when "mode"
        mode
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "in2"
        self.in2 = value
      when "mode"
        self.mode = value
      else
        super
      end
    end
  end

  # `<feColorMatrix>` — applies a color matrix transformation.
  class SVGFEColorMatrixElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def values
      reflected_string("values")
    end

    def values=(v)
      set_reflected_string("values", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "type"
        type
      when "values"
        values
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "type"
        self.type = value
      when "values"
        self.values = value
      else
        super
      end
    end
  end

  # `<feFlood>` — fills the primitive region with a solid color.
  class SVGFEFloodElement < SVGFilterPrimitiveElement
    def flood_color
      reflected_string("flood-color")
    end

    def flood_color=(v)
      set_reflected_string("flood-color", v)
    end

    def flood_opacity
      reflected_string("flood-opacity")
    end

    def flood_opacity=(v)
      set_reflected_string("flood-opacity", v)
    end

    def __js_get__(key)
      case key
      when "flood-color"
        flood_color
      when "flood-opacity"
        flood_opacity
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "flood-color"
        self.flood_color = value
      when "flood-opacity"
        self.flood_opacity = value
      else
        super
      end
    end
  end

  # `<feComposite>` — composes two inputs per the Porter–Duff
  # `operator` (or arithmetic with k1..k4).
  class SVGFECompositeElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def in2
      reflected_string("in2")
    end

    def in2=(v)
      set_reflected_string("in2", v)
    end

    def operator
      reflected_string("operator")
    end

    def operator=(v)
      set_reflected_string("operator", v)
    end

    def k1
      reflected_string("k1")
    end

    def k1=(v)
      set_reflected_string("k1", v)
    end

    def k2
      reflected_string("k2")
    end

    def k2=(v)
      set_reflected_string("k2", v)
    end

    def k3
      reflected_string("k3")
    end

    def k3=(v)
      set_reflected_string("k3", v)
    end

    def k4
      reflected_string("k4")
    end

    def k4=(v)
      set_reflected_string("k4", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "in2"
        in2
      when "operator"
        operator
      when "k1"
        k1
      when "k2"
        k2
      when "k3"
        k3
      when "k4"
        k4
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "in2"
        self.in2 = value
      when "operator"
        self.operator = value
      when "k1"
        self.k1 = value
      when "k2"
        self.k2 = value
      when "k3"
        self.k3 = value
      when "k4"
        self.k4 = value
      else
        super
      end
    end
  end

  # `<feMerge>` — composites a list of inputs (children are
  # `<feMergeNode>` elements naming the inputs).
  class SVGFEMergeElement < SVGFilterPrimitiveElement
  end

  # `<feMergeNode>` — a single input reference inside `<feMerge>`.
  # Not itself a region/result primitive, but inherits the common
  # attribute machinery from SVGElement.
  class SVGFEMergeNodeElement < SVGElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def __js_get__(key)
      key == "in" ? in1 : super
    end

    def __js_set__(key, value)
      key == "in" ? (self.in1 = value) : super
    end
  end

  # `<feComponentTransfer>` — per-channel color transfer. Children are
  # `<feFuncR>` / `<feFuncG>` / `<feFuncB>` / `<feFuncA>`.
  class SVGFEComponentTransferElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def __js_get__(key)
      key == "in" ? in1 : super
    end

    def __js_set__(key, value)
      key == "in" ? (self.in1 = value) : super
    end
  end

  # Base for `<feFuncR>` / `<feFuncG>` / `<feFuncB>` / `<feFuncA>`.
  # Per the DOM spec, all four share the same attribute set
  # (`type` + parameters by type) so they're modeled as a single
  # superclass that the four tag-specific subclasses inherit verbatim.
  class SVGComponentTransferFunctionElement < SVGElement
    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def table_values
      reflected_string("tableValues")
    end

    def table_values=(v)
      set_reflected_string("tableValues", v)
    end

    def slope
      reflected_string("slope")
    end

    def slope=(v)
      set_reflected_string("slope", v)
    end

    def intercept
      reflected_string("intercept")
    end

    def intercept=(v)
      set_reflected_string("intercept", v)
    end

    def amplitude
      reflected_string("amplitude")
    end

    def amplitude=(v)
      set_reflected_string("amplitude", v)
    end

    def exponent
      reflected_string("exponent")
    end

    def exponent=(v)
      set_reflected_string("exponent", v)
    end

    def offset
      reflected_string("offset")
    end

    def offset=(v)
      set_reflected_string("offset", v)
    end

    def __js_get__(key)
      case key
      when "type"
        type
      when "tableValues"
        table_values
      when "slope"
        slope
      when "intercept"
        intercept
      when "amplitude"
        amplitude
      when "exponent"
        exponent
      when "offset"
        offset
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        self.type = value
      when "tableValues"
        self.table_values = value
      when "slope"
        self.slope = value
      when "intercept"
        self.intercept = value
      when "amplitude"
        self.amplitude = value
      when "exponent"
        self.exponent = value
      when "offset"
        self.offset = value
      else
        super
      end
    end
  end

  class SVGFEFuncRElement < SVGComponentTransferFunctionElement
  end

  class SVGFEFuncGElement < SVGComponentTransferFunctionElement
  end

  class SVGFEFuncBElement < SVGComponentTransferFunctionElement
  end

  class SVGFEFuncAElement < SVGComponentTransferFunctionElement
  end

  # `<feTile>` — fills the primitive region by tiling its input.
  class SVGFETileElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def __js_get__(key)
      key == "in" ? in1 : super
    end

    def __js_set__(key, value)
      key == "in" ? (self.in1 = value) : super
    end
  end

  # `<feMorphology>` — morphological erode / dilate.
  class SVGFEMorphologyElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def operator
      reflected_string("operator")
    end

    def operator=(v)
      set_reflected_string("operator", v)
    end

    def radius
      reflected_string("radius")
    end

    def radius=(v)
      set_reflected_string("radius", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "operator"
        operator
      when "radius"
        radius
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "operator"
        self.operator = value
      when "radius"
        self.radius = value
      else
        super
      end
    end
  end

  # `<feImage>` — fetches an external image (or references one by id)
  # and supplies it as input to the filter pipeline.
  class SVGFEImageElement < SVGFilterPrimitiveElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def preserve_aspect_ratio
      reflected_string("preserveAspectRatio")
    end

    def preserve_aspect_ratio=(v)
      set_reflected_string("preserveAspectRatio", v)
    end

    def crossorigin
      reflected_string("crossorigin")
    end

    def crossorigin=(v)
      set_reflected_string("crossorigin", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "preserveAspectRatio"
        preserve_aspect_ratio
      when "crossorigin"
        crossorigin
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href"
        self.href = value
      when "preserveAspectRatio"
        self.preserve_aspect_ratio = value
      when "crossorigin"
        self.crossorigin = value
      else
        super
      end
    end
  end

  # `<feDropShadow>` — convenience filter primitive producing a
  # drop shadow (Gaussian-blurred translated copy of the input,
  # composited under the source).
  class SVGFEDropShadowElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def dx
      reflected_string("dx")
    end

    def dx=(v)
      set_reflected_string("dx", v)
    end

    def dy
      reflected_string("dy")
    end

    def dy=(v)
      set_reflected_string("dy", v)
    end

    def std_deviation
      reflected_string("stdDeviation")
    end

    def std_deviation=(v)
      set_reflected_string("stdDeviation", v)
    end

    def flood_color
      reflected_string("flood-color")
    end

    def flood_color=(v)
      set_reflected_string("flood-color", v)
    end

    def flood_opacity
      reflected_string("flood-opacity")
    end

    def flood_opacity=(v)
      set_reflected_string("flood-opacity", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "dx"
        dx
      when "dy"
        dy
      when "stdDeviation"
        std_deviation
      when "flood-color"
        flood_color
      when "flood-opacity"
        flood_opacity
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "dx"
        self.dx = value
      when "dy"
        self.dy = value
      when "stdDeviation"
        self.std_deviation = value
      when "flood-color"
        self.flood_color = value
      when "flood-opacity"
        self.flood_opacity = value
      else
        super
      end
    end
  end

  # `<feTurbulence>` — Perlin noise generator. No `in` (it produces
  # output rather than transforming an input).
  class SVGFETurbulenceElement < SVGFilterPrimitiveElement
    def base_frequency
      reflected_string("baseFrequency")
    end

    def base_frequency=(v)
      set_reflected_string("baseFrequency", v)
    end

    def num_octaves
      reflected_string("numOctaves")
    end

    def num_octaves=(v)
      set_reflected_string("numOctaves", v)
    end

    def seed
      reflected_string("seed")
    end

    def seed=(v)
      set_reflected_string("seed", v)
    end

    def stitch_tiles
      reflected_string("stitchTiles")
    end

    def stitch_tiles=(v)
      set_reflected_string("stitchTiles", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def __js_get__(key)
      case key
      when "baseFrequency"
        base_frequency
      when "numOctaves"
        num_octaves
      when "seed"
        seed
      when "stitchTiles"
        stitch_tiles
      when "type"
        type
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "baseFrequency"
        self.base_frequency = value
      when "numOctaves"
        self.num_octaves = value
      when "seed"
        self.seed = value
      when "stitchTiles"
        self.stitch_tiles = value
      when "type"
        self.type = value
      else
        super
      end
    end
  end

  # `<feDisplacementMap>` — uses one input as a map to displace pixels
  # of another.
  class SVGFEDisplacementMapElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def in2
      reflected_string("in2")
    end

    def in2=(v)
      set_reflected_string("in2", v)
    end

    def scale
      reflected_string("scale")
    end

    def scale=(v)
      set_reflected_string("scale", v)
    end

    def x_channel_selector
      reflected_string("xChannelSelector")
    end

    def x_channel_selector=(v)
      set_reflected_string("xChannelSelector", v)
    end

    def y_channel_selector
      reflected_string("yChannelSelector")
    end

    def y_channel_selector=(v)
      set_reflected_string("yChannelSelector", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "in2"
        in2
      when "scale"
        scale
      when "xChannelSelector"
        x_channel_selector
      when "yChannelSelector"
        y_channel_selector
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "in2"
        self.in2 = value
      when "scale"
        self.scale = value
      when "xChannelSelector"
        self.x_channel_selector = value
      when "yChannelSelector"
        self.y_channel_selector = value
      else
        super
      end
    end
  end

  # ===== Light sources =====
  #
  # Children of `<feDiffuseLighting>` / `<feSpecularLighting>` (which
  # aren't specialized yet — see SVGElement fallback). Light sources
  # carry no `result` of their own; they configure the parent primitive.

  # `<feDistantLight>` — light at infinity, characterized only by direction.
  class SVGFEDistantLightElement < SVGElement
    def azimuth
      reflected_string("azimuth")
    end

    def azimuth=(v)
      set_reflected_string("azimuth", v)
    end

    def elevation
      reflected_string("elevation")
    end

    def elevation=(v)
      set_reflected_string("elevation", v)
    end

    def __js_get__(key)
      case key
      when "azimuth"
        azimuth
      when "elevation"
        elevation
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "azimuth"
        self.azimuth = value
      when "elevation"
        self.elevation = value
      else
        super
      end
    end
  end

  # `<fePointLight>` — point light source at (x, y, z).
  class SVGFEPointLightElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def z
      reflected_string("z")
    end

    def z=(v)
      set_reflected_string("z", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "z"
        z
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "z"
        self.z = value
      else
        super
      end
    end
  end

  # `<feSpotLight>` — spotlight emanating from (x, y, z), aimed at
  # (pointsAtX, pointsAtY, pointsAtZ). `limitingConeAngle` restricts
  # the spread; `specularExponent` controls focus falloff.
  class SVGFESpotLightElement < SVGElement
    def x
      reflected_string("x")
    end

    def x=(v)
      set_reflected_string("x", v)
    end

    def y
      reflected_string("y")
    end

    def y=(v)
      set_reflected_string("y", v)
    end

    def z
      reflected_string("z")
    end

    def z=(v)
      set_reflected_string("z", v)
    end

    def points_at_x
      reflected_string("pointsAtX")
    end

    def points_at_x=(v)
      set_reflected_string("pointsAtX", v)
    end

    def points_at_y
      reflected_string("pointsAtY")
    end

    def points_at_y=(v)
      set_reflected_string("pointsAtY", v)
    end

    def points_at_z
      reflected_string("pointsAtZ")
    end

    def points_at_z=(v)
      set_reflected_string("pointsAtZ", v)
    end

    def specular_exponent
      reflected_string("specularExponent")
    end

    def specular_exponent=(v)
      set_reflected_string("specularExponent", v)
    end

    def limiting_cone_angle
      reflected_string("limitingConeAngle")
    end

    def limiting_cone_angle=(v)
      set_reflected_string("limitingConeAngle", v)
    end

    def __js_get__(key)
      case key
      when "x"
        x
      when "y"
        y
      when "z"
        z
      when "pointsAtX"
        points_at_x
      when "pointsAtY"
        points_at_y
      when "pointsAtZ"
        points_at_z
      when "specularExponent"
        specular_exponent
      when "limitingConeAngle"
        limiting_cone_angle
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "x"
        self.x = value
      when "y"
        self.y = value
      when "z"
        self.z = value
      when "pointsAtX"
        self.points_at_x = value
      when "pointsAtY"
        self.points_at_y = value
      when "pointsAtZ"
        self.points_at_z = value
      when "specularExponent"
        self.specular_exponent = value
      when "limitingConeAngle"
        self.limiting_cone_angle = value
      else
        super
      end
    end
  end

  # `<feConvolveMatrix>` — applies an arbitrary convolution kernel.
  # Heavy in attribute count; all are reflected.
  class SVGFEConvolveMatrixElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def order
      reflected_string("order")
    end

    def order=(v)
      set_reflected_string("order", v)
    end

    def kernel_matrix
      reflected_string("kernelMatrix")
    end

    def kernel_matrix=(v)
      set_reflected_string("kernelMatrix", v)
    end

    def divisor
      reflected_string("divisor")
    end

    def divisor=(v)
      set_reflected_string("divisor", v)
    end

    def bias
      reflected_string("bias")
    end

    def bias=(v)
      set_reflected_string("bias", v)
    end

    def target_x
      reflected_string("targetX")
    end

    def target_x=(v)
      set_reflected_string("targetX", v)
    end

    def target_y
      reflected_string("targetY")
    end

    def target_y=(v)
      set_reflected_string("targetY", v)
    end

    def edge_mode
      reflected_string("edgeMode")
    end

    def edge_mode=(v)
      set_reflected_string("edgeMode", v)
    end

    def kernel_unit_length
      reflected_string("kernelUnitLength")
    end

    def kernel_unit_length=(v)
      set_reflected_string("kernelUnitLength", v)
    end

    def preserve_alpha
      reflected_string("preserveAlpha")
    end

    def preserve_alpha=(v)
      set_reflected_string("preserveAlpha", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "order"
        order
      when "kernelMatrix"
        kernel_matrix
      when "divisor"
        divisor
      when "bias"
        bias
      when "targetX"
        target_x
      when "targetY"
        target_y
      when "edgeMode"
        edge_mode
      when "kernelUnitLength"
        kernel_unit_length
      when "preserveAlpha"
        preserve_alpha
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "order"
        self.order = value
      when "kernelMatrix"
        self.kernel_matrix = value
      when "divisor"
        self.divisor = value
      when "bias"
        self.bias = value
      when "targetX"
        self.target_x = value
      when "targetY"
        self.target_y = value
      when "edgeMode"
        self.edge_mode = value
      when "kernelUnitLength"
        self.kernel_unit_length = value
      when "preserveAlpha"
        self.preserve_alpha = value
      else
        super
      end
    end
  end

  # `<feDiffuseLighting>` — applies diffuse lighting based on a
  # bumpmap input and a light source child (one of feDistantLight /
  # fePointLight / feSpotLight).
  class SVGFEDiffuseLightingElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def surface_scale
      reflected_string("surfaceScale")
    end

    def surface_scale=(v)
      set_reflected_string("surfaceScale", v)
    end

    def diffuse_constant
      reflected_string("diffuseConstant")
    end

    def diffuse_constant=(v)
      set_reflected_string("diffuseConstant", v)
    end

    def kernel_unit_length
      reflected_string("kernelUnitLength")
    end

    def kernel_unit_length=(v)
      set_reflected_string("kernelUnitLength", v)
    end

    def lighting_color
      reflected_string("lighting-color")
    end

    def lighting_color=(v)
      set_reflected_string("lighting-color", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "surfaceScale"
        surface_scale
      when "diffuseConstant"
        diffuse_constant
      when "kernelUnitLength"
        kernel_unit_length
      when "lighting-color"
        lighting_color
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "surfaceScale"
        self.surface_scale = value
      when "diffuseConstant"
        self.diffuse_constant = value
      when "kernelUnitLength"
        self.kernel_unit_length = value
      when "lighting-color"
        self.lighting_color = value
      else
        super
      end
    end
  end

  # `<feSpecularLighting>` — applies specular (highlight) lighting.
  # Like feDiffuseLighting but with a specularConstant and
  # specularExponent driving the highlight shape.
  class SVGFESpecularLightingElement < SVGFilterPrimitiveElement
    def in1
      reflected_string("in")
    end

    def in1=(v)
      set_reflected_string("in", v)
    end

    def surface_scale
      reflected_string("surfaceScale")
    end

    def surface_scale=(v)
      set_reflected_string("surfaceScale", v)
    end

    def specular_constant
      reflected_string("specularConstant")
    end

    def specular_constant=(v)
      set_reflected_string("specularConstant", v)
    end

    def specular_exponent
      reflected_string("specularExponent")
    end

    def specular_exponent=(v)
      set_reflected_string("specularExponent", v)
    end

    def kernel_unit_length
      reflected_string("kernelUnitLength")
    end

    def kernel_unit_length=(v)
      set_reflected_string("kernelUnitLength", v)
    end

    def lighting_color
      reflected_string("lighting-color")
    end

    def lighting_color=(v)
      set_reflected_string("lighting-color", v)
    end

    def __js_get__(key)
      case key
      when "in"
        in1
      when "surfaceScale"
        surface_scale
      when "specularConstant"
        specular_constant
      when "specularExponent"
        specular_exponent
      when "kernelUnitLength"
        kernel_unit_length
      when "lighting-color"
        lighting_color
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "in"
        self.in1 = value
      when "surfaceScale"
        self.surface_scale = value
      when "specularConstant"
        self.specular_constant = value
      when "specularExponent"
        self.specular_exponent = value
      when "kernelUnitLength"
        self.kernel_unit_length = value
      when "lighting-color"
        self.lighting_color = value
      else
        super
      end
    end
  end

  # ===== SMIL animation =====
  #
  # `<animate>` and friends — declarative animation built into the
  # SVG spec. Supported in all major browsers as of Baseline 2023.

  # Base class for SMIL animation elements; carries the timing
  # attributes (`begin`, `end`, `dur`, etc.) that all animation
  # elements share.
  class SVGAnimationElement < SVGElement
    # The `begin` / `end` Ruby methods correspond exactly to the SVG
    # attributes; Ruby permits these as method names (block keywords
    # are only special syntax, not identifier-level reserved words).
    def begin
      reflected_string("begin")
    end

    def begin=(v)
      set_reflected_string("begin", v)
    end

    def end
      reflected_string("end")
    end

    def end=(v)
      set_reflected_string("end", v)
    end

    def dur
      reflected_string("dur")
    end

    def dur=(v)
      set_reflected_string("dur", v)
    end

    def min
      reflected_string("min")
    end

    def min=(v)
      set_reflected_string("min", v)
    end

    def max
      reflected_string("max")
    end

    def max=(v)
      set_reflected_string("max", v)
    end

    def restart
      reflected_string("restart")
    end

    def restart=(v)
      set_reflected_string("restart", v)
    end

    def repeat_count
      reflected_string("repeatCount")
    end

    def repeat_count=(v)
      set_reflected_string("repeatCount", v)
    end

    def repeat_dur
      reflected_string("repeatDur")
    end

    def repeat_dur=(v)
      set_reflected_string("repeatDur", v)
    end

    def fill
      reflected_string("fill")
    end

    def fill=(v)
      set_reflected_string("fill", v)
    end

    def attribute_name
      reflected_string("attributeName")
    end

    def attribute_name=(v)
      set_reflected_string("attributeName", v)
    end

    def __js_get__(key)
      case key
      when "begin"
        self.begin
      when "end"
        self.end
      when "dur"
        dur
      when "min"
        min
      when "max"
        max
      when "restart"
        restart
      when "repeatCount"
        repeat_count
      when "repeatDur"
        repeat_dur
      when "fill"
        fill
      when "attributeName"
        attribute_name
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "begin"
        self.begin = value
      when "end"
        self.end = value
      when "dur"
        self.dur = value
      when "min"
        self.min = value
      when "max"
        self.max = value
      when "restart"
        self.restart = value
      when "repeatCount"
        self.repeat_count = value
      when "repeatDur"
        self.repeat_dur = value
      when "fill"
        self.fill = value
      when "attributeName"
        self.attribute_name = value
      else
        super
      end
    end
  end

  # `<animate>` — animates a target attribute's value over time.
  class SVGAnimateElement < SVGAnimationElement
    def from
      reflected_string("from")
    end

    def from=(v)
      set_reflected_string("from", v)
    end

    def to
      reflected_string("to")
    end

    def to=(v)
      set_reflected_string("to", v)
    end

    def by
      reflected_string("by")
    end

    def by=(v)
      set_reflected_string("by", v)
    end

    def values
      reflected_string("values")
    end

    def values=(v)
      set_reflected_string("values", v)
    end

    def calc_mode
      reflected_string("calcMode")
    end

    def calc_mode=(v)
      set_reflected_string("calcMode", v)
    end

    def key_times
      reflected_string("keyTimes")
    end

    def key_times=(v)
      set_reflected_string("keyTimes", v)
    end

    def key_splines
      reflected_string("keySplines")
    end

    def key_splines=(v)
      set_reflected_string("keySplines", v)
    end

    def __js_get__(key)
      case key
      when "from"
        from
      when "to"
        to
      when "by"
        by
      when "values"
        values
      when "calcMode"
        calc_mode
      when "keyTimes"
        key_times
      when "keySplines"
        key_splines
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "from"
        self.from = value
      when "to"
        self.to = value
      when "by"
        self.by = value
      when "values"
        self.values = value
      when "calcMode"
        self.calc_mode = value
      when "keyTimes"
        self.key_times = value
      when "keySplines"
        self.key_splines = value
      else
        super
      end
    end
  end

  # `<animateTransform>` — animates a transform attribute (translate,
  # scale, rotate, skewX, skewY).
  class SVGAnimateTransformElement < SVGAnimationElement
    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def from
      reflected_string("from")
    end

    def from=(v)
      set_reflected_string("from", v)
    end

    def to
      reflected_string("to")
    end

    def to=(v)
      set_reflected_string("to", v)
    end

    def by
      reflected_string("by")
    end

    def by=(v)
      set_reflected_string("by", v)
    end

    def values
      reflected_string("values")
    end

    def values=(v)
      set_reflected_string("values", v)
    end

    def __js_get__(key)
      case key
      when "type"
        type
      when "from"
        from
      when "to"
        to
      when "by"
        by
      when "values"
        values
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        self.type = value
      when "from"
        self.from = value
      when "to"
        self.to = value
      when "by"
        self.by = value
      when "values"
        self.values = value
      else
        super
      end
    end
  end

  # `<animateMotion>` — animates an element along a path.
  class SVGAnimateMotionElement < SVGAnimationElement
    def path
      reflected_string("path")
    end

    def path=(v)
      set_reflected_string("path", v)
    end

    def key_points
      reflected_string("keyPoints")
    end

    def key_points=(v)
      set_reflected_string("keyPoints", v)
    end

    def rotate
      reflected_string("rotate")
    end

    def rotate=(v)
      set_reflected_string("rotate", v)
    end

    def origin
      reflected_string("origin")
    end

    def origin=(v)
      set_reflected_string("origin", v)
    end

    def __js_get__(key)
      case key
      when "path"
        path
      when "keyPoints"
        key_points
      when "rotate"
        rotate
      when "origin"
        origin
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "path"
        self.path = value
      when "keyPoints"
        self.key_points = value
      when "rotate"
        self.rotate = value
      when "origin"
        self.origin = value
      else
        super
      end
    end
  end

  # `<set>` — sets the value of an attribute for a specified duration
  # (no interpolation between values).
  class SVGSetElement < SVGAnimationElement
    def to
      reflected_string("to")
    end

    def to=(v)
      set_reflected_string("to", v)
    end

    def __js_get__(key)
      key == "to" ? to : super
    end

    def __js_set__(key, value)
      key == "to" ? (self.to = value) : super
    end
  end

  # `<mpath>` — child of `<animateMotion>` that references an external
  # `<path>` by href.
  class SVGMPathElement < SVGElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      key == "href" ? href : super
    end

    def __js_set__(key, value)
      key == "href" ? (self.href = value) : super
    end
  end

  # `<discard>` (SVG 2) — removes the target element from the document
  # at a specified time.
  class SVGDiscardElement < SVGAnimationElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def __js_get__(key)
      key == "href" ? href : super
    end

    def __js_set__(key, value)
      key == "href" ? (self.href = value) : super
    end
  end

  # Tag-name → class lookup. Keys are the lowercased form Nokogiri::HTML5
  # stores in the tree. Tags absent from this table fall through to
  # `Dommy::SVGElement` via `element_class_for`.
  SVG_ELEMENT_CLASSES = {
    "svg" => SVGSVGElement,
    "g" => SVGGElement,
    "circle" => SVGCircleElement,
    "rect" => SVGRectElement,
    "ellipse" => SVGEllipseElement,
    "line" => SVGLineElement,
    "polygon" => SVGPolygonElement,
    "polyline" => SVGPolylineElement,
    "path" => SVGPathElement,
    "text" => SVGTextElement,
    "tspan" => SVGTSpanElement,
    "defs" => SVGDefsElement,
    "use" => SVGUseElement,
    "image" => SVGImageElement,
    "symbol" => SVGSymbolElement,
    "foreignobject" => SVGForeignObjectElement,
    "title" => SVGTitleElement,
    "desc" => SVGDescElement,
    "mask" => SVGMaskElement,
    "clippath" => SVGClipPathElement,
    "pattern" => SVGPatternElement,
    "lineargradient" => SVGLinearGradientElement,
    "radialgradient" => SVGRadialGradientElement,
    "stop" => SVGStopElement,
    "filter" => SVGFilterElement,
    "marker" => SVGMarkerElement,

    # Recommended additions
    "a" => SVGAElement,
    "textpath" => SVGTextPathElement,
    "view" => SVGViewElement,
    "switch" => SVGSwitchElement,
    "metadata" => SVGMetadataElement,

    # Filter primitives (common ones)
    "fegaussianblur" => SVGFEGaussianBlurElement,
    "feoffset" => SVGFEOffsetElement,
    "feblend" => SVGFEBlendElement,
    "fecolormatrix" => SVGFEColorMatrixElement,
    "feflood" => SVGFEFloodElement,
    "fecomposite" => SVGFECompositeElement,
    "femerge" => SVGFEMergeElement,
    "femergenode" => SVGFEMergeNodeElement,
    "fecomponenttransfer" => SVGFEComponentTransferElement,
    "fefuncr" => SVGFEFuncRElement,
    "fefuncg" => SVGFEFuncGElement,
    "fefuncb" => SVGFEFuncBElement,
    "fefunca" => SVGFEFuncAElement,
    "fetile" => SVGFETileElement,
    "femorphology" => SVGFEMorphologyElement,
    "feimage" => SVGFEImageElement,
    "fedropshadow" => SVGFEDropShadowElement,
    "feturbulence" => SVGFETurbulenceElement,
    "fedisplacementmap" => SVGFEDisplacementMapElement,
    "fedistantlight" => SVGFEDistantLightElement,
    "fepointlight" => SVGFEPointLightElement,
    "fespotlight" => SVGFESpotLightElement,
    "feconvolvematrix" => SVGFEConvolveMatrixElement,
    "fediffuselighting" => SVGFEDiffuseLightingElement,
    "fespecularlighting" => SVGFESpecularLightingElement,

    # SMIL animation
    "animate" => SVGAnimateElement,
    "animatetransform" => SVGAnimateTransformElement,
    "animatemotion" => SVGAnimateMotionElement,
    "set" => SVGSetElement,
    "mpath" => SVGMPathElement,
    "discard" => SVGDiscardElement
  }.freeze
end
