# frozen_string_literal: true

require_relative "test_helper"

# `[ReflectSetter]` attributes: the setter reflects like any other, and the
# getter is prose. So the two halves disagree on purpose, and what each does is
# worth pinning separately — the setter's conversion comes from the IDL type
# (`unsigned long` for img.width, `double` for meter.value), and the getter from
# whatever the prose says.
class TestReflectSetter < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window(<<~HTML).document
      <img id="img"><meter id="meter"></meter><progress id="progress"></progress>
      <select id="select"><option id="option">text</option></select>
    HTML
  end

  def el(id) = @doc.get_element_by_id(id)

  # A `double` setter writes the SHORTEST representation, so an integral value
  # loses its trailing ".0" — meter and progress used to spell this differently,
  # and progress wrote "5.0".
  def test_a_double_setter_writes_the_shortest_representation
    meter = el("meter")
    meter.value = 5

    assert_equal("5", meter.get_attribute("value"))

    meter.value = 0.25

    assert_equal("0.25", meter.get_attribute("value"))

    progress = el("progress")
    progress.value = 5

    assert_equal("5", progress.get_attribute("value"))
  end

  # WebIDL's `double` is the restricted one: a value that coerces to NaN or an
  # infinity is a TypeError rather than an attribute reading "NaN".
  def test_a_double_setter_rejects_a_non_finite_value
    assert_raises(Dommy::Bridge::TypeError) { el("meter").value = "foobar" }
    assert_raises(Dommy::Bridge::TypeError) { el("progress").value = Float::INFINITY }
  end

  # img.width is an `unsigned long`, so the setter converts out of range before
  # writing, exactly as a reflected one does.
  def test_an_unsigned_long_setter_converts_before_writing
    img = el("img")
    img.width = 120

    assert_equal("120", img.get_attribute("width"))
    assert_equal(120, img.width)

    img.width = 3_000_000_000

    assert_equal("0", img.get_attribute("width"))
  end

  # Its getter is the prose: dommy renders nothing and loads no image, so the
  # algorithm reaches its last step — the attribute, parsed, or 0.
  def test_the_image_dimension_getter_falls_back_to_the_attribute
    img = el("img")
    img.set_attribute("width", "12abc")

    assert_equal(12, img.width)

    img.set_attribute("width", "-5")

    assert_equal(0, img.width)

    img.remove_attribute("width")

    assert_equal(0, img.width)
  end

  # option.value and option.label reflect on the way out and fall back to the
  # option's text on the way in.
  def test_an_options_value_falls_back_to_its_text
    option = el("option")

    assert_equal("text", option.value)

    option.value = "v"

    assert_equal("v", option.get_attribute("value"))
    assert_equal("v", option.value)
  end
end
