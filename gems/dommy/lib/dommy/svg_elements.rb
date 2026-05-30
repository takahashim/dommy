# frozen_string_literal: true

module Dommy
  # Base for specialized SVGElement subclasses. Mirrors HTMLElement's
  # role for HTML: a thin layer over Element that adds reflection
  # helpers (via Internal::ReflectedAttributes) and a few attribute
  # accessors that apply to every SVG element.
  #
  # Every subclass declares its reflected attributes via the
  # `reflect_string` DSL (Internal::ReflectedAttributes): one line per
  # element generates the snake_case getter/setter pair AND the JS-bridge
  # `__js_get__` / `__js_set__` routing, so the Ruby accessor, the JS
  # getter, and the JS setter can't drift apart. Ruby property names are
  # snake_case; the JS key defaults to camelCase(name) and the content
  # attribute is whatever the SVG spec defines (often camelCase:
  # `viewBox`, `gradientUnits`, `preserveAspectRatio`).
  class SVGElement < Element
    include Internal::ReflectedAttributes

    # SVG attribute names are case-sensitive (`viewBox` ≠ `viewbox`).
    # Element's get/set/has/remove_attribute consult this flag to
    # decide whether to lowercase the attribute name.
    def case_sensitive_attribute_names?
      true
    end

    # Common SVG attributes shared across all elements.
    reflect_string :id, class_name: "class", tabindex: { js: "tabIndex" }
  end

  # `<svg>` — the root of an SVG subtree.
  class SVGSVGElement < SVGElement
    reflect_string :width, :height, :view_box, :preserve_aspect_ratio
  end

  # `<g>` — generic group; only inherits common attributes.
  class SVGGElement < SVGElement
  end

  # `<circle>` — cx, cy, r.
  class SVGCircleElement < SVGElement
    reflect_string :cx, :cy, :r
  end

  # `<rect>` — x, y, width, height, rx, ry.
  class SVGRectElement < SVGElement
    reflect_string :x, :y, :width, :height, :rx, :ry
  end

  # `<ellipse>` — cx, cy, rx, ry.
  class SVGEllipseElement < SVGElement
    reflect_string :cx, :cy, :rx, :ry
  end

  # `<line>` — x1, y1, x2, y2.
  class SVGLineElement < SVGElement
    reflect_string :x1, :y1, :x2, :y2
  end

  # `<polygon>` — points (a string like "0,0 10,0 10,10").
  class SVGPolygonElement < SVGElement
    reflect_string :points
  end

  # `<polyline>` — points.
  class SVGPolylineElement < SVGElement
    reflect_string :points
  end

  # `<path>` — d (path data), pathLength.
  class SVGPathElement < SVGElement
    reflect_string :d, :path_length
  end

  # `<text>` — x, y, dx, dy, text-anchor.
  class SVGTextElement < SVGElement
    reflect_string :x, :y, :dx, :dy, text_anchor: "text-anchor"
  end

  # `<tspan>` — same coord attrs as <text>.
  class SVGTSpanElement < SVGElement
    reflect_string :x, :y, :dx, :dy
  end

  # `<defs>` — container for reusable definitions; no special attrs.
  class SVGDefsElement < SVGElement
  end

  # `<use>` — href, x, y, width, height.
  class SVGUseElement < SVGElement
    reflect_string :href, :x, :y, :width, :height
  end

  # `<image>` — href + box + preserveAspectRatio.
  class SVGImageElement < SVGElement
    reflect_string :href, :x, :y, :width, :height, :preserve_aspect_ratio
  end

  # `<symbol>` — reusable template; viewBox + preserveAspectRatio.
  class SVGSymbolElement < SVGElement
    reflect_string :view_box, :preserve_aspect_ratio
  end

  # `<foreignObject>` — embeds non-SVG content; standard box attrs.
  class SVGForeignObjectElement < SVGElement
    reflect_string :x, :y, :width, :height
  end

  # `<title>` (inside SVG) — distinct from HTMLTitleElement.
  class SVGTitleElement < SVGElement
  end

  # `<desc>` — accessibility description.
  class SVGDescElement < SVGElement
  end

  # `<mask>` — alpha mask region.
  class SVGMaskElement < SVGElement
    reflect_string :x, :y, :width, :height, :mask_units, :mask_content_units
  end

  # `<clipPath>` — clipping region.
  class SVGClipPathElement < SVGElement
    reflect_string :clip_path_units
  end

  # `<pattern>` — tile-based paint server.
  class SVGPatternElement < SVGElement
    reflect_string :x, :y, :width, :height, :pattern_units, :pattern_content_units, :href
  end

  # `<linearGradient>` — linear color gradient paint server.
  class SVGLinearGradientElement < SVGElement
    reflect_string :x1, :y1, :x2, :y2, :gradient_units, :gradient_transform, :spread_method, :href
  end

  # `<radialGradient>` — radial color gradient paint server.
  class SVGRadialGradientElement < SVGElement
    reflect_string :cx, :cy, :r, :fx, :fy, :fr, :gradient_units, :gradient_transform, :spread_method, :href
  end

  # `<stop>` — a single gradient color stop.
  class SVGStopElement < SVGElement
    reflect_string :offset
  end

  # `<filter>` — filter region + primitive units + href.
  class SVGFilterElement < SVGElement
    reflect_string :x, :y, :width, :height, :filter_units, :primitive_units, :href
  end

  # `<marker>` — arrowhead / line marker.
  class SVGMarkerElement < SVGElement
    reflect_string :ref_x, :ref_y, :marker_width, :marker_height, :orient, :marker_units, :view_box, :preserve_aspect_ratio
  end

  # `<a>` (in the SVG namespace) — a hyperlink wrapping SVG content.
  # Distinct from `HTMLAnchorElement` (the HTML `<a>`).
  class SVGAElement < SVGElement
    reflect_string :href, :target, :download, :rel, :type
  end

  # `<textPath>` — text laid out along a path.
  class SVGTextPathElement < SVGElement
    reflect_string :href, :start_offset, :spacing, :text_length, :length_adjust, method_attr: { attr: "method", js: "method" }
  end

  # `<view>` — a named view region referenced by SVG fragment identifier.
  class SVGViewElement < SVGElement
    reflect_string :view_box, :preserve_aspect_ratio, :zoom_and_pan
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
    reflect_string :x, :y, :width, :height, :result
  end

  # `<feGaussianBlur>` — Gaussian blur primitive.
  class SVGFEGaussianBlurElement < SVGFilterPrimitiveElement
    reflect_string :std_deviation, :edge_mode, in1: { attr: "in", js: "in" }
  end

  # `<feOffset>` — translates input by (dx, dy).
  class SVGFEOffsetElement < SVGFilterPrimitiveElement
    reflect_string :dx, :dy, in1: { attr: "in", js: "in" }
  end

  # `<feBlend>` — blends two inputs with a mode.
  class SVGFEBlendElement < SVGFilterPrimitiveElement
    reflect_string :in2, :mode, in1: { attr: "in", js: "in" }
  end

  # `<feColorMatrix>` — applies a color matrix transformation.
  class SVGFEColorMatrixElement < SVGFilterPrimitiveElement
    reflect_string :type, :values, in1: { attr: "in", js: "in" }
  end

  # `<feFlood>` — fills the primitive region with a solid color.
  class SVGFEFloodElement < SVGFilterPrimitiveElement
    reflect_string flood_color: { attr: "flood-color", js: "flood-color" }, flood_opacity: { attr: "flood-opacity", js: "flood-opacity" }
  end

  # `<feComposite>` — composes two inputs per the Porter–Duff
  # `operator` (or arithmetic with k1..k4).
  class SVGFECompositeElement < SVGFilterPrimitiveElement
    reflect_string :in2, :operator, :k1, :k2, :k3, :k4, in1: { attr: "in", js: "in" }
  end

  # `<feMerge>` — composites a list of inputs (children are
  # `<feMergeNode>` elements naming the inputs).
  class SVGFEMergeElement < SVGFilterPrimitiveElement
  end

  # `<feMergeNode>` — a single input reference inside `<feMerge>`.
  # Not itself a region/result primitive, but inherits the common
  # attribute machinery from SVGElement.
  class SVGFEMergeNodeElement < SVGElement
    reflect_string in1: { attr: "in", js: "in" }
  end

  # `<feComponentTransfer>` — per-channel color transfer. Children are
  # `<feFuncR>` / `<feFuncG>` / `<feFuncB>` / `<feFuncA>`.
  class SVGFEComponentTransferElement < SVGFilterPrimitiveElement
    reflect_string in1: { attr: "in", js: "in" }
  end

  # Base for `<feFuncR>` / `<feFuncG>` / `<feFuncB>` / `<feFuncA>`.
  # Per the DOM spec, all four share the same attribute set
  # (`type` + parameters by type) so they're modeled as a single
  # superclass that the four tag-specific subclasses inherit verbatim.
  class SVGComponentTransferFunctionElement < SVGElement
    reflect_string :type, :table_values, :slope, :intercept, :amplitude, :exponent, :offset
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
    reflect_string in1: { attr: "in", js: "in" }
  end

  # `<feMorphology>` — morphological erode / dilate.
  class SVGFEMorphologyElement < SVGFilterPrimitiveElement
    reflect_string :operator, :radius, in1: { attr: "in", js: "in" }
  end

  # `<feImage>` — fetches an external image (or references one by id)
  # and supplies it as input to the filter pipeline.
  class SVGFEImageElement < SVGFilterPrimitiveElement
    reflect_string :href, :preserve_aspect_ratio, :crossorigin
  end

  # `<feDropShadow>` — convenience filter primitive producing a
  # drop shadow (Gaussian-blurred translated copy of the input,
  # composited under the source).
  class SVGFEDropShadowElement < SVGFilterPrimitiveElement
    reflect_string :dx, :dy, :std_deviation, in1: { attr: "in", js: "in" }, flood_color: { attr: "flood-color", js: "flood-color" }, flood_opacity: { attr: "flood-opacity", js: "flood-opacity" }
  end

  # `<feTurbulence>` — Perlin noise generator. No `in` (it produces
  # output rather than transforming an input).
  class SVGFETurbulenceElement < SVGFilterPrimitiveElement
    reflect_string :base_frequency, :num_octaves, :seed, :stitch_tiles, :type
  end

  # `<feDisplacementMap>` — uses one input as a map to displace pixels
  # of another.
  class SVGFEDisplacementMapElement < SVGFilterPrimitiveElement
    reflect_string :in2, :scale, :x_channel_selector, :y_channel_selector, in1: { attr: "in", js: "in" }
  end

  # ===== Light sources =====
  #
  # Children of `<feDiffuseLighting>` / `<feSpecularLighting>` (which
  # aren't specialized yet — see SVGElement fallback). Light sources
  # carry no `result` of their own; they configure the parent primitive.

  # `<feDistantLight>` — light at infinity, characterized only by direction.
  class SVGFEDistantLightElement < SVGElement
    reflect_string :azimuth, :elevation
  end

  # `<fePointLight>` — point light source at (x, y, z).
  class SVGFEPointLightElement < SVGElement
    reflect_string :x, :y, :z
  end

  # `<feSpotLight>` — spotlight emanating from (x, y, z), aimed at
  # (pointsAtX, pointsAtY, pointsAtZ). `limitingConeAngle` restricts
  # the spread; `specularExponent` controls focus falloff.
  class SVGFESpotLightElement < SVGElement
    reflect_string :x, :y, :z, :points_at_x, :points_at_y, :points_at_z, :specular_exponent, :limiting_cone_angle
  end

  # `<feConvolveMatrix>` — applies an arbitrary convolution kernel.
  # Heavy in attribute count; all are reflected.
  class SVGFEConvolveMatrixElement < SVGFilterPrimitiveElement
    reflect_string :order, :kernel_matrix, :divisor, :bias, :target_x, :target_y, :edge_mode, :kernel_unit_length, :preserve_alpha, in1: { attr: "in", js: "in" }
  end

  # `<feDiffuseLighting>` — applies diffuse lighting based on a
  # bumpmap input and a light source child (one of feDistantLight /
  # fePointLight / feSpotLight).
  class SVGFEDiffuseLightingElement < SVGFilterPrimitiveElement
    reflect_string :surface_scale, :diffuse_constant, :kernel_unit_length, in1: { attr: "in", js: "in" }, lighting_color: { attr: "lighting-color", js: "lighting-color" }
  end

  # `<feSpecularLighting>` — applies specular (highlight) lighting.
  # Like feDiffuseLighting but with a specularConstant and
  # specularExponent driving the highlight shape.
  class SVGFESpecularLightingElement < SVGFilterPrimitiveElement
    reflect_string :surface_scale, :specular_constant, :specular_exponent, :kernel_unit_length, in1: { attr: "in", js: "in" }, lighting_color: { attr: "lighting-color", js: "lighting-color" }
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
    reflect_string :begin, :end, :dur, :min, :max, :restart, :repeat_count, :repeat_dur, :fill, :attribute_name
  end

  # `<animate>` — animates a target attribute's value over time.
  class SVGAnimateElement < SVGAnimationElement
    reflect_string :from, :to, :by, :values, :calc_mode, :key_times, :key_splines
  end

  # `<animateTransform>` — animates a transform attribute (translate,
  # scale, rotate, skewX, skewY).
  class SVGAnimateTransformElement < SVGAnimationElement
    reflect_string :type, :from, :to, :by, :values
  end

  # `<animateMotion>` — animates an element along a path.
  class SVGAnimateMotionElement < SVGAnimationElement
    reflect_string :path, :key_points, :rotate, :origin
  end

  # `<set>` — sets the value of an attribute for a specified duration
  # (no interpolation between values).
  class SVGSetElement < SVGAnimationElement
    reflect_string :to
  end

  # `<mpath>` — child of `<animateMotion>` that references an external
  # `<path>` by href.
  class SVGMPathElement < SVGElement
    reflect_string :href
  end

  # `<discard>` (SVG 2) — removes the target element from the document
  # at a specified time.
  class SVGDiscardElement < SVGAnimationElement
    reflect_string :href
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
