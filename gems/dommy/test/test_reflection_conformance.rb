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
end
