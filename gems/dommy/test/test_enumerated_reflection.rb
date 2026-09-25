# frozen_string_literal: true

require_relative "test_helper"

# The `reflect_enumerated` mechanism itself (Internal::ReflectedAttributes),
# exercised through a throwaway attribute on a real element class rather than
# any spec-defined one — the per-attribute keyword tables are
# TestEnumeratedReflection's job, in the migration commits that follow.
# `__test_demo__` follows the project's `__test_` dunder convention for
# exactly this: a method that exists only for a test to hang off of.
class TestEnumeratedReflector < Minitest::Test
  include DommyTestHelper

  class Dommy::HTMLDivElement
    reflect_enumerated __test_demo__: {
      attr: "data-test-demo", js: "__test_demo__", keywords: %w[a b],
      missing: "a", invalid: "b", empty: "a"
    }
    reflect_enumerated __test_nullable_demo__: {
      attr: "data-test-nullable-demo", js: "__test_nullable_demo__",
      keywords: %w[a], missing: nil, invalid: nil, nullable: true
    }
  end

  def setup
    @win = make_window("<div id='d'></div>")
    @div = @win.document.get_element_by_id("d")
  end

  def test_missing_reads_the_missing_default
    assert_equal("a", @div.__test_demo__)
  end

  def test_a_matched_keyword_is_returned_lowercased_and_ascii_case_insensitively
    @div.set_attribute("data-test-demo", "B")

    assert_equal("b", @div.__test_demo__)
  end

  def test_an_unrecognized_value_reads_the_invalid_default
    @div.set_attribute("data-test-demo", "bogus")

    assert_equal("b", @div.__test_demo__)
  end

  def test_an_empty_value_reads_the_empty_default_over_the_invalid_one
    @div.set_attribute("data-test-demo", "")

    assert_equal("a", @div.__test_demo__)
  end

  def test_the_setter_writes_the_attribute_unchanged
    @div.__test_demo__ = "B"

    assert_equal("B", @div.get_attribute("data-test-demo"))
    assert_equal("b", @div.__test_demo__)
  end

  def test_no_associated_keyword_is_declared_via_the_js_bridge_too
    assert_equal("a", @div.__js_get__("__test_demo__"))

    @div.__js_set__("__test_demo__", "bogus")
    assert_equal("bogus", @div.get_attribute("data-test-demo"))
  end

  # `nullable:` (a `DOMString?` attribute, e.g. `crossOrigin`): a state with no
  # keyword reads back null rather than "".
  def test_nullable_missing_and_invalid_read_null
    assert_nil(@div.__test_nullable_demo__)

    @div.set_attribute("data-test-nullable-demo", "bogus")
    assert_nil(@div.__test_nullable_demo__)
  end

  def test_nullable_setter_deletes_the_attribute_for_null
    @div.__test_nullable_demo__ = "a"
    assert(@div.has_attribute?("data-test-nullable-demo"))

    @div.__test_nullable_demo__ = nil
    refute(@div.has_attribute?("data-test-nullable-demo"))
  end

  def test_declared_type_is_enumerated_for_the_webidl_audit
    assert_equal(:enumerated, Dommy::HTMLDivElement.reflect_specs["__test_demo__"][:type])
  end
end

# Enumerated IDL attributes — HTML's "reflect ... limited to only known
# values" (§2.6.1), written entirely in prose: the specs' own IDL carries no
# [Reflect] for these at all, which is why `reflect_string` used to be wrong
# for every one of them (test/support/webidl_audit.rb's `invented_reflect_gaps`
# watches for that class of bug). What the algorithm does is checked here, per
# attribute, through both Ruby and the JS bridge; which attributes these are is
# checked against the specs' own IDL by test_webidl_conformance.rb.
# https://html.spec.whatwg.org/multipage/common-dom-interfaces.html#reflecting-content-attributes-in-idl-attributes
class TestEnumeratedReflection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <form id="form"></form>
      <button id="button"></button>
      <input id="input">
      <img id="img">
      <track id="track">
      <video id="video"></video>
      <table><tr><th id="th"></th></tr></table>
      <link id="link">
      <script id="script"></script>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  # form.method: keywords get/post/dialog, missing and invalid both "get".
  # (The Ruby accessor is `method_attr`, not `method` — that name is already
  # `Kernel#method`.)
  def test_form_method_missing_reads_the_missing_default
    assert_equal("get", el("form").method_attr)
    assert_equal("get", el("form").__js_get__("method"))
  end

  def test_form_method_canonicalizes_the_matched_keyword
    el("form").set_attribute("method", "POST")

    assert_equal("post", el("form").method_attr)
  end

  def test_form_method_invalid_reads_the_invalid_default
    el("form").set_attribute("method", "bogus")

    assert_equal("get", el("form").method_attr)
  end

  def test_form_method_setter_writes_the_attribute_unchanged
    el("form").method_attr = "post"

    assert_equal("post", el("form").get_attribute("method"))
  end

  # form.enctype / form.autocomplete: same shape, spot-checked.
  def test_form_enctype_defaults_and_canonicalizes
    assert_equal("application/x-www-form-urlencoded", el("form").enctype)

    el("form").set_attribute("enctype", "MULTIPART/FORM-DATA")
    assert_equal("multipart/form-data", el("form").enctype)

    el("form").set_attribute("enctype", "bogus")
    assert_equal("application/x-www-form-urlencoded", el("form").enctype)
  end

  def test_form_autocomplete_defaults_to_on
    assert_equal("on", el("form").autocomplete)

    el("form").set_attribute("autocomplete", "off")
    assert_equal("off", el("form").autocomplete)

    el("form").set_attribute("autocomplete", "bogus")
    assert_equal("on", el("form").autocomplete)
  end

  # button.formMethod / input.formMethod: unlike <form>'s own `method`, the
  # per-control attribute has NO missing value default — only invalid.
  def test_form_control_form_method_has_no_missing_default
    assert_equal("", el("button").form_method)
    assert_equal("", el("input").form_method)
  end

  def test_form_control_form_method_invalid_reads_get
    el("button").set_attribute("formmethod", "bogus")

    assert_equal("get", el("button").form_method)
  end

  def test_form_control_form_enctype_has_no_missing_default
    assert_equal("", el("input").form_enctype)

    el("input").set_attribute("formenctype", "bogus")
    assert_equal("application/x-www-form-urlencoded", el("input").form_enctype)
  end

  # img.crossOrigin: DOMString?, missing -> null, "" and invalid -> "anonymous".
  def test_cross_origin_missing_is_null
    assert_nil(el("img").crossorigin)
    assert_nil(el("img").__js_get__("crossOrigin"))
  end

  def test_cross_origin_empty_value_default_is_anonymous
    el("img").set_attribute("crossorigin", "")

    assert_equal("anonymous", el("img").crossorigin)
  end

  def test_cross_origin_invalid_value_default_is_anonymous
    el("img").set_attribute("crossorigin", "bogus")

    assert_equal("anonymous", el("img").crossorigin)
  end

  def test_cross_origin_use_credentials_keyword
    el("img").set_attribute("crossorigin", "USE-CREDENTIALS")

    assert_equal("use-credentials", el("img").crossorigin)
  end

  def test_cross_origin_setter_null_removes_the_attribute
    el("img").crossorigin = "anonymous"
    assert(el("img").has_attribute?("crossorigin"))

    el("img").__js_set__("crossOrigin", nil)
    refute(el("img").has_attribute?("crossorigin"))
  end

  # img.decoding: missing/invalid both "auto".
  def test_decoding_defaults_to_auto
    assert_equal("auto", el("img").decoding)

    el("img").set_attribute("decoding", "bogus")
    assert_equal("auto", el("img").decoding)

    el("img").set_attribute("decoding", "SYNC")
    assert_equal("sync", el("img").decoding)
  end

  # img.loading: HTML's lazy loading attribute, missing/invalid both "eager".
  def test_loading_defaults_to_eager
    assert_equal("eager", el("img").loading)

    el("img").set_attribute("loading", "bogus")
    assert_equal("eager", el("img").loading)

    el("img").set_attribute("loading", "LAZY")
    assert_equal("lazy", el("img").loading)
  end

  # img.referrerPolicy: every referrer policy token including "" is a keyword;
  # missing/invalid both read back "".
  def test_referrer_policy_defaults_to_empty
    assert_equal("", el("img").referrer_policy)

    el("img").set_attribute("referrerpolicy", "BOGUS")
    assert_equal("", el("img").referrer_policy)

    el("img").set_attribute("referrerpolicy", "no-referrer")
    assert_equal("no-referrer", el("img").referrer_policy)
  end

  # track.kind: missing -> "subtitles", invalid -> "metadata".
  def test_track_kind_missing_and_invalid_defaults
    assert_equal("subtitles", el("track").kind)

    el("track").set_attribute("kind", "bogus")
    assert_equal("metadata", el("track").kind)

    el("track").set_attribute("kind", "CAPTIONS")
    assert_equal("captions", el("track").kind)
  end

  # video.preload: missing/invalid default to "metadata" (HTML's suggested
  # compromise for the implementation-defined default); "" is its own empty
  # value default, "auto".
  def test_preload_defaults
    assert_equal("metadata", el("video").preload)

    el("video").set_attribute("preload", "bogus")
    assert_equal("metadata", el("video").preload)

    el("video").set_attribute("preload", "")
    assert_equal("auto", el("video").preload)

    el("video").set_attribute("preload", "NONE")
    assert_equal("none", el("video").preload)
  end

  # th.scope: the Auto state (missing/invalid) has no keyword, so it reads "".
  def test_scope_missing_and_invalid_have_no_keyword
    assert_equal("", el("th").scope)

    el("th").set_attribute("scope", "bogus")
    assert_equal("", el("th").scope)

    el("th").set_attribute("scope", "ROW")
    assert_equal("row", el("th").scope)
  end

  # link.as: the union of preload and module-preload destinations; no missing
  # or invalid value default at all. (The Ruby accessor is `as_attr` — `as` is
  # a Ruby keyword — but the JS-visible name is plain "as".)
  def test_link_as_has_no_default
    assert_equal("", el("link").as_attr)
    assert_equal("", el("link").__js_get__("as"))

    el("link").set_attribute("as", "bogus")
    assert_equal("", el("link").as_attr)

    el("link").set_attribute("as", "SCRIPT")
    assert_equal("script", el("link").as_attr)
  end

  # A module preload destination is a known value too (json / text / a
  # script-like destination), while a bare Fetch request destination that is
  # not a preload destination (audio, video, document, embed, object, …) has no
  # state.
  def test_link_as_accepts_module_preload_destinations_only
    %w[json text audioworklet paintworklet worker].each do |keyword|
      el("link").set_attribute("as", keyword)
      assert_equal(keyword, el("link").as_attr, keyword)
    end

    %w[video audio document embed object iframe manifest xslt].each do |keyword|
      el("link").set_attribute("as", keyword)
      assert_equal("", el("link").as_attr, "#{keyword} is not a preload destination")
    end
  end

  # script.async: HTML's "force async" flag — true for a script this session
  # created (createElement / cloneNode) until something proves otherwise.
  def test_created_script_is_force_async
    created = @doc.create_element("script")

    assert(created.async)
    refute(created.has_attribute?("async"))
  end

  def test_cloned_script_is_force_async
    clone = el("script").clone_node(false)

    assert(clone.async)
  end

  def test_parsed_script_is_not_force_async
    refute(el("script").async)
  end

  def test_parser_inserted_via_inner_html_is_not_force_async
    @doc.body.inner_html = "<script id='fresh'></script>"

    refute(el("fresh").async)
  end

  def test_setting_async_true_reflects_and_clears_force_async
    created = @doc.create_element("script")
    created.async = true

    assert(created.has_attribute?("async"))
    assert(created.async)

    created.async = false
    refute(created.has_attribute?("async"))
    refute(created.async)
  end

  def test_adding_the_async_attribute_clears_force_async
    created = @doc.create_element("script")
    created.set_attribute("async", "")

    assert(created.async)

    created.remove_attribute("async")
    refute(created.async)
  end

  # A <template>'s content is parser-produced too, but it is moved into its
  # DocumentFragment by Internal::TemplateContentRegistry — a path that
  # bypasses both Document#__internal_run_parsed_insertion_steps__ and
  # Element#mark_fragment_scripts_started, so the registry has to clear force
  # async on its own.
  def test_a_script_parsed_via_template_inner_html_is_not_force_async
    template = @doc.create_element("template")
    template.inner_html = "<script>1</script>"

    refute(template.content.first_child.async)
  end

  # Nested inside another element, still found and cleared.
  def test_a_nested_script_parsed_via_template_inner_html_is_not_force_async
    template = @doc.create_element("template")
    template.inner_html = "<div><script>1</script></div>"

    refute(template.content.query_selector("script").async)
  end

  def test_a_script_in_an_initially_parsed_template_is_not_force_async
    win = make_window("<template><script>1</script></template>")
    template = win.document.query_selector("template")

    refute(template.content.first_child.async)
  end

  # input.type: 22 keywords, missing/invalid both "text".
  def test_input_type_missing_and_invalid_default_to_text
    assert_equal("text", el("input").type)

    el("input").set_attribute("type", "bogus")
    assert_equal("text", el("input").type)

    el("input").set_attribute("type", "CHECKBOX")
    assert_equal("checkbox", el("input").type)
  end
end
