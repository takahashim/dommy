# frozen_string_literal: true

require_relative "test_helper"

# Coverage for the additional specialized HTMLElement subclasses:
# media (audio/video/source/track), iframe, picture, list items,
# time, data, area/map, object/embed, head metadata, quote/mod.
class TestHTMLMediaElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_audio_class_dispatch
    assert_kind_of(Dommy::HTMLAudioElement, @doc.create_element("audio"))
    assert_kind_of(Dommy::HTMLMediaElement, @doc.create_element("audio"))
  end

  def test_video_class_dispatch
    assert_kind_of(Dommy::HTMLVideoElement, @doc.create_element("video"))
    assert_kind_of(Dommy::HTMLMediaElement, @doc.create_element("video"))
  end

  def test_media_src_reflects
    a = @doc.create_element("audio")
    a.src = "/x.mp3"
    assert_equal("/x.mp3", a.src)
    assert_equal("/x.mp3", a.get_attribute("src"))
  end

  def test_media_default_paused_true
    assert_equal(true, @doc.create_element("video").paused)
  end

  def test_media_play_returns_resolved_promise
    a = @doc.create_element("audio")
    p = a.play
    assert_kind_of(Dommy::PromiseValue, p)
    refute(a.paused)
  end

  def test_media_pause_flips_paused
    a = @doc.create_element("audio")
    a.play
    a.pause
    assert(a.paused)
  end

  def test_media_loop_reflects
    v = @doc.create_element("video")
    v.loop_ = true
    assert(v.loop_)
    assert(v.has_attribute?("loop"))
  end

  def test_media_autoplay_reflects
    v = @doc.create_element("video")
    v.autoplay = true
    assert(v.autoplay)
  end

  def test_media_muted_is_runtime_only
    v = @doc.create_element("video")
    v.muted = true
    assert(v.muted)
    refute(v.has_attribute?("muted"))
  end

  def test_media_volume_default
    assert_in_delta(1.0, @doc.create_element("video").volume)
  end

  def test_media_volume_setter
    v = @doc.create_element("video")
    v.volume = 0.25
    assert_in_delta(0.25, v.volume)
  end

  def test_media_currentTime_default_zero
    assert_in_delta(0.0, @doc.create_element("video").current_time)
  end

  def test_media_canPlayType_returns_empty
    assert_equal("", @doc.create_element("audio").can_play_type("audio/mpeg"))
  end

  def test_media_network_state_constants
    v = @doc.create_element("video")
    assert_equal(0, v.__js_get__("NETWORK_EMPTY"))
    assert_equal(3, v.__js_get__("NETWORK_NO_SOURCE"))
  end

  def test_video_poster_reflects
    v = @doc.create_element("video")
    v.poster = "/p.jpg"
    assert_equal("/p.jpg", v.poster)
  end

  def test_video_dimensions
    v = @doc.create_element("video")
    v.width = 640
    v.height = 480
    assert_equal(640, v.width)
    assert_equal(480, v.height)
    assert_equal(640, v.video_width)
  end

  def test_video_plays_inline
    v = @doc.create_element("video")
    v.plays_inline = true
    assert(v.plays_inline)
  end
end

class TestHTMLSourceTrack < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_source_dispatch
    assert_kind_of(Dommy::HTMLSourceElement, @doc.create_element("source"))
  end

  def test_source_attributes
    s = @doc.create_element("source")
    s.src = "/a.webm"
    s.type = "video/webm"
    s.media = "(min-width: 800px)"
    assert_equal("/a.webm", s.src)
    assert_equal("video/webm", s.type)
    assert_equal("(min-width: 800px)", s.media)
  end

  def test_track_dispatch
    assert_kind_of(Dommy::HTMLTrackElement, @doc.create_element("track"))
  end

  def test_track_default_flag
    t = @doc.create_element("track")
    t.default_ = true
    assert(t.default_)
    assert(t.has_attribute?("default"))
  end

  def test_track_kind_default
    assert_equal("", @doc.create_element("track").kind)
  end
end

class TestHTMLIFrameElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_iframe_dispatch
    assert_kind_of(Dommy::HTMLIFrameElement, @doc.create_element("iframe"))
  end

  def test_iframe_src
    f = @doc.create_element("iframe")
    f.src = "/inner"
    assert_equal("/inner", f.src)
  end

  def test_iframe_srcdoc
    f = @doc.create_element("iframe")
    f.srcdoc = "<p>x</p>"
    assert_equal("<p>x</p>", f.srcdoc)
  end

  def test_iframe_sandbox
    f = @doc.create_element("iframe")
    f.sandbox = "allow-scripts"
    assert_equal("allow-scripts", f.sandbox)
  end

  def test_iframe_allow_fullscreen
    f = @doc.create_element("iframe")
    f.allow_fullscreen = true
    assert(f.allow_fullscreen)
    assert(f.has_attribute?("allowfullscreen"))
  end

  def test_iframe_content_document_nil
    assert_nil(@doc.create_element("iframe").content_document)
  end

  def test_iframe_content_window_nil
    assert_nil(@doc.create_element("iframe").content_window)
  end
end

class TestHTMLListElements < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_ol_dispatch
    assert_kind_of(Dommy::HTMLOListElement, @doc.create_element("ol"))
  end

  def test_ol_start_default_one
    assert_equal(1, @doc.create_element("ol").start)
  end

  def test_ol_start_reflected_as_int
    ol = @doc.create_element("ol")
    ol.start = 5
    assert_equal(5, ol.start)
    assert_equal("5", ol.get_attribute("start"))
  end

  def test_ol_reversed
    ol = @doc.create_element("ol")
    ol.reversed = true
    assert(ol.reversed)
  end

  def test_ul_dispatch
    assert_kind_of(Dommy::HTMLUListElement, @doc.create_element("ul"))
  end

  def test_li_dispatch
    assert_kind_of(Dommy::HTMLLIElement, @doc.create_element("li"))
  end

  def test_li_value_int_when_set
    li = @doc.create_element("li")
    li.value = 7
    assert_equal(7, li.value)
  end

  def test_li_value_defaults_to_zero_when_unset
    # `value` reflects a long with default 0 per the HTML Standard.
    assert_equal(0, @doc.create_element("li").value)
  end

  def test_ol_start_defaults_to_one_and_parses_leading_integer
    ol = @doc.create_element("ol")
    assert_equal(1, ol.start)            # unspecified → default 1
    ol.set_attribute("start", "A")
    assert_equal(1, ol.start)            # unparseable → default 1
    ol.set_attribute("start", "3xyz")
    assert_equal(3, ol.start)            # leading integer, trailing junk ignored
  end
end

class TestHTMLTimeData < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_time_dispatch
    assert_kind_of(Dommy::HTMLTimeElement, @doc.create_element("time"))
  end

  def test_time_dateTime
    t = @doc.create_element("time")
    t.date_time = "2026-05-21"
    assert_equal("2026-05-21", t.date_time)
    assert_equal("2026-05-21", t.get_attribute("datetime"))
  end

  def test_data_dispatch
    assert_kind_of(Dommy::HTMLDataElement, @doc.create_element("data"))
  end

  def test_data_value
    d = @doc.create_element("data")
    d.value = "42"
    assert_equal("42", d.value)
  end
end

class TestHTMLAreaMap < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_area_dispatch
    assert_kind_of(Dommy::HTMLAreaElement, @doc.create_element("area"))
  end

  def test_area_attrs
    a = @doc.create_element("area")
    a.alt = "icon"
    a.shape = "rect"
    a.coords = "0,0,10,10"
    a.href = "/x"
    assert_equal("icon", a.alt)
    assert_equal("rect", a.shape)
    assert_equal("0,0,10,10", a.coords)
    assert_equal("/x", a.href)
  end

  def test_map_dispatch
    assert_kind_of(Dommy::HTMLMapElement, @doc.create_element("map"))
  end

  def test_map_name
    m = @doc.create_element("map")
    m.name = "navmap"
    assert_equal("navmap", m.name)
  end

  def test_map_areas_collection
    @doc.body.inner_html = "<map name='m'><area shape='rect'><area shape='circle'></map>"
    m = @doc.query_selector("map")
    assert_kind_of(Dommy::HTMLCollection, m.areas)
    assert_equal(2, m.areas.length)
  end
end

class TestHTMLObjectEmbed < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_object_dispatch
    assert_kind_of(Dommy::HTMLObjectElement, @doc.create_element("object"))
  end

  def test_object_data_attr
    o = @doc.create_element("object")
    o.data = "/x.swf"
    assert_equal("/x.swf", o.data)
  end

  def test_object_useMap
    o = @doc.create_element("object")
    o.use_map = "#m"
    assert_equal("#m", o.use_map)
    assert_equal("#m", o.get_attribute("usemap"))
  end

  def test_embed_dispatch
    assert_kind_of(Dommy::HTMLEmbedElement, @doc.create_element("embed"))
  end

  def test_embed_src
    e = @doc.create_element("embed")
    e.src = "/x.pdf"
    assert_equal("/x.pdf", e.src)
  end
end

class TestHTMLHeadMetadata < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_base_dispatch
    assert_kind_of(Dommy::HTMLBaseElement, @doc.create_element("base"))
  end

  def test_base_href
    b = @doc.create_element("base")
    b.href = "/root/"
    assert_equal("/root/", b.href)
  end

  def test_meta_dispatch
    assert_kind_of(Dommy::HTMLMetaElement, @doc.create_element("meta"))
  end

  def test_meta_attrs
    m = @doc.create_element("meta")
    m.name = "viewport"
    m.content = "width=device-width"
    m.http_equiv = "Refresh"
    assert_equal("viewport", m.name)
    assert_equal("width=device-width", m.content)
    assert_equal("Refresh", m.http_equiv)
    assert_equal("Refresh", m.get_attribute("http-equiv"))
  end

  def test_meta_charset
    m = @doc.create_element("meta")
    m.charset = "utf-8"
    assert_equal("utf-8", m.charset)
  end

  def test_style_dispatch
    assert_kind_of(Dommy::HTMLStyleElement, @doc.create_element("style"))
  end

  def test_style_disabled_runtime_only
    s = @doc.create_element("style")
    s.disabled = true
    assert(s.disabled)
    refute(s.has_attribute?("disabled"))
  end

  def test_title_dispatch
    assert_kind_of(Dommy::HTMLTitleElement, @doc.create_element("title"))
  end

  def test_title_text
    t = @doc.create_element("title")
    t.text = "Page"
    assert_equal("Page", t.text)
    assert_equal("Page", t.text_content)
  end
end

class TestHTMLQuoteMod < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_q_dispatch
    assert_kind_of(Dommy::HTMLQuoteElement, @doc.create_element("q"))
  end

  def test_blockquote_dispatch
    assert_kind_of(Dommy::HTMLQuoteElement, @doc.create_element("blockquote"))
  end

  def test_quote_cite
    q = @doc.create_element("q")
    q.cite = "https://example.com/source"
    assert_equal("https://example.com/source", q.cite)
  end

  def test_ins_dispatch
    assert_kind_of(Dommy::HTMLModElement, @doc.create_element("ins"))
  end

  def test_del_dispatch
    assert_kind_of(Dommy::HTMLModElement, @doc.create_element("del"))
  end

  def test_mod_cite_and_dateTime
    d = @doc.create_element("del")
    d.cite = "/log"
    d.date_time = "2026-05-21"
    assert_equal("/log", d.cite)
    assert_equal("2026-05-21", d.date_time)
  end
end

class TestHTMLIdentitySubclasses < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_div_dispatch
    assert_kind_of(Dommy::HTMLDivElement, @doc.create_element("div"))
  end

  def test_span_dispatch
    assert_kind_of(Dommy::HTMLSpanElement, @doc.create_element("span"))
  end

  def test_p_dispatch
    assert_kind_of(Dommy::HTMLParagraphElement, @doc.create_element("p"))
  end

  def test_heading_dispatch_h1_through_h6
    %w[h1 h2 h3 h4 h5 h6].each do |tag|
      el = @doc.create_element(tag)
      assert_kind_of(Dommy::HTMLHeadingElement, el, "#{tag} should be HTMLHeadingElement")
    end
  end

  def test_br_hr_pre_dispatch
    assert_kind_of(Dommy::HTMLBRElement, @doc.create_element("br"))
    assert_kind_of(Dommy::HTMLHRElement, @doc.create_element("hr"))
    assert_kind_of(Dommy::HTMLPreElement, @doc.create_element("pre"))
  end

  def test_picture_dispatch
    assert_kind_of(Dommy::HTMLPictureElement, @doc.create_element("picture"))
  end

  def test_body_head_html_dispatch
    @doc.body.inner_html = "<div></div>"
    assert_kind_of(Dommy::HTMLBodyElement, @doc.body)
  end
end
