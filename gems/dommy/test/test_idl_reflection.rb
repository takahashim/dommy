# frozen_string_literal: true

require_relative "test_helper"

# HTML §2.6.1 reflection declared from the specs' own IDL
# (Internal::IdlReflection and its generated table): the obsolete attributes
# §16 still reflects, the [ReflectNonNegative] / [ReflectPositiveWithFallback]
# ones, the prose-only overlay, and hand declarations winning over generated
# ones.
class TestIdlReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @document = make_window("").document
  end

  def element(name) = @document.create_element(name)

  def test_obsolete_string_attributes_reflect
    table = element("table")
    table.set_attribute("cellpadding", "4")
    assert_equal "4", table.__js_get__("cellPadding")
    table.__js_set__("bgColor", "red")
    assert_equal "red", table.get_attribute("bgcolor")
    assert_equal "", element("td").__js_get__("ch")
    cell = element("td")
    cell.__js_set__("chOff", "2")
    assert_equal "2", cell.get_attribute("charoff")
  end

  def test_obsolete_body_attributes_reflect
    body = element("body")
    body.__js_set__("aLink", "#f00")
    body.__js_set__("vLink", "#0f0")
    assert_equal "#f00", body.get_attribute("alink")
    assert_equal "#0f0", body.get_attribute("vlink")
    body.set_attribute("text", "black")
    assert_equal "black", body.__js_get__("text")
  end

  def test_obsolete_boolean_long_and_url_attributes_reflect
    area = element("area")
    assert_equal false, area.__js_get__("noHref")
    area.__js_set__("noHref", true)
    assert_equal "", area.get_attribute("nohref")

    img = element("img")
    img.set_attribute("hspace", "-3")
    assert_equal 0, img.__js_get__("hspace")
    img.set_attribute("vspace", "7px")
    assert_equal 7, img.__js_get__("vspace")

    pre = element("pre")
    pre.__js_set__("width", -4)
    assert_equal "-4", pre.get_attribute("width")
    assert_equal(-4, pre.__js_get__("width"))

    frame = element("frame")
    frame.set_attribute("longdesc", "desc.html")
    assert frame.__js_get__("longDesc").end_with?("/desc.html")
    frame.set_attribute("longdesc", "http://[bad")
    assert_equal "http://[bad", frame.__js_get__("longDesc")
  end

  def test_a_name_and_embed_name_reflect
    anchor = element("a")
    anchor.__js_set__("name", "top")
    assert_equal "top", anchor.get_attribute("name")
    assert_equal "", element("embed").__js_get__("align")
  end

  # [ReflectNonNegative]: -1 for a missing or negative value, and a negative
  # value set throws.
  def test_max_length_is_non_negative
    %w[input textarea].each do |name|
      control = element(name)
      assert_equal(-1, control.max_length)
      control.set_attribute("maxlength", "-2")
      assert_equal(-1, control.max_length)
      control.max_length = 5
      assert_equal "5", control.get_attribute("maxlength")
      assert_raises(Dommy::DOMException::IndexSizeError) { control.min_length = -1 }
    end
  end

  # [ReflectPositiveWithFallback, ReflectDefault=20] / =2.
  def test_textarea_rows_and_cols_fall_back
    textarea = element("textarea")
    assert_equal 2, textarea.rows
    assert_equal 20, textarea.cols
    textarea.cols = 0
    assert_equal "20", textarea.get_attribute("cols")
    textarea.set_attribute("rows", "0")
    assert_equal 2, textarea.rows
  end

  # The prose half of the overlay: input.size is limited to only positive
  # numbers with a default of 20; canvas width/height default to 300/150.
  def test_overlay_reflections
    input = element("input")
    assert_equal 20, input.size
    input.set_attribute("size", "0")
    assert_equal 20, input.size
    assert_raises(Dommy::DOMException::IndexSizeError) { input.size = 0 }

    canvas = element("canvas")
    assert_equal [300, 150], [canvas.width, canvas.height]
  end

  def test_progress_max_is_positive_with_default
    progress = element("progress")
    assert_in_delta 1.0, progress.max
    progress.max = -1
    assert_nil progress.get_attribute("max")
  end

  def test_details_open_reaches_js
    details = element("details")
    details.__js_set__("open", true)
    assert details.has_attribute?("open")
    assert_equal true, details.__js_get__("open")
  end

  def test_generated_declarations_are_marked
    spec = Dommy::HTMLTableElement.reflect_specs["cellPadding"]
    assert spec[:generated]
    assert_equal :string, spec[:type]
    refute Dommy::HTMLAnchorElement.reflect_specs["relList"][:generated]
  end

  # A class's own accessor wins over the IDL: HTMLImageElement writes the
  # width getter (the rendered dimension) and gets only the [ReflectSetter]
  # half from the declaration it makes itself.
  def test_hand_written_accessors_win
    spec = Dommy::HTMLImageElement.reflect_specs["width"]
    assert_equal :setter_only, spec[:type]
    refute spec[:generated]
  end

  def test_menu_and_marquee_elements
    assert_instance_of Dommy::HTMLMenuElement, element("menu")
    menu = element("menu")
    menu.__js_set__("compact", true)
    assert menu.has_attribute?("compact")

    marquee = element("marquee")
    assert_instance_of Dommy::HTMLMarqueeElement, marquee
    assert_equal "", marquee.__js_get__("behavior")
    assert_equal 6, marquee.__js_get__("scrollAmount")
    assert_equal 85, marquee.__js_get__("scrollDelay")
  end

  # The marquee loop count: -1 unless the attribute parses to at least 1; a
  # set value other than -1 or a positive number is ignored.
  def test_marquee_loop
    marquee = element("marquee")
    assert_equal(-1, marquee.__js_get__("loop"))
    marquee.set_attribute("loop", "0")
    assert_equal(-1, marquee.__js_get__("loop"))
    marquee.__js_set__("loop", 3)
    assert_equal "3", marquee.get_attribute("loop")
    marquee.__js_set__("loop", 0)
    assert_equal "3", marquee.get_attribute("loop")
    marquee.__js_set__("loop", -1)
    assert_equal "-1", marquee.get_attribute("loop")
    marquee.stop
    refute marquee.turned_on?
    marquee.start
    assert marquee.turned_on?
  end

  # Document's legacy colors reflect the body element's attributes, and read
  # "" / ignore writes without a body element (or with a frameset).
  def test_document_legacy_colors
    document = make_window("").document
    document.__js_set__("bgColor", "white")
    assert_equal "white", document.body.get_attribute("bgcolor")
    document.body.set_attribute("text", "black")
    assert_equal "black", document.__js_get__("fgColor")
    document.__js_set__("alinkColor", nil)
    assert_equal "", document.body.get_attribute("alink")
    %w[linkColor vlinkColor].each { |key| assert_equal "", document.__js_get__(key) }

    document.body.remove
    assert_equal "", document.__js_get__("bgColor")
    document.__js_set__("bgColor", "red")
    assert_nil document.query_selector("[bgcolor=red]")
  end

  def test_aria_tables_come_from_the_idl
    aria = Dommy::Internal::ElementAria
    assert_equal "aria-activedescendant", aria::ELEMENT_ATTRIBUTES["ariaActiveDescendantElement"]
    assert_equal "aria-labelledby", aria::ELEMENTS_ATTRIBUTES["ariaLabelledByElements"]
    assert_equal "aria-valuetext", aria::STRING_ATTRIBUTES["ariaValueText"]
    assert_equal "role", aria::STRING_ATTRIBUTES["role"]
  end
end
