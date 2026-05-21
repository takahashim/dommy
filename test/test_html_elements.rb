# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLAnchorElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      "<a id='link' href='https://example.com:8080/path?q=1#section' target='_blank' download='file.pdf' rel='noopener'>X</a>"
    )
    @doc = @win.document
    @a = @doc.get_element_by_id("link")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLAnchorElement, @a)
  end

  def test_url_components
    assert_equal("example.com:8080", @a.host)
    assert_equal("example.com", @a.hostname)
    assert_equal("/path", @a.pathname)
    assert_equal("https:", @a.protocol)
    assert_equal("?q=1", @a.search)
    assert_equal("#section", @a.hash)
    assert_equal("8080", @a.port)
    assert_equal("https://example.com:8080", @a.origin)
  end

  def test_reflected_attrs
    assert_equal("_blank", @a.target)
    assert_equal("file.pdf", @a.download)
    assert_equal("noopener", @a.rel)
  end

  def test_target_setter
    @a.target = "_self"
    assert_equal("_self", @a.get_attribute("target"))
  end
end

class TestHTMLFormElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form id="f" name="login" action="/post" method="post" enctype="multipart/form-data">
          <input name="email">
          <input name="password" type="password">
          <button type="submit">Go</button>
        </form>
      HTML
    )
    @doc = @win.document
    @form = @doc.get_element_by_id("f")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLFormElement, @form)
  end

  def test_reflected_attrs
    assert_equal("login", @form.name)
    assert_equal("/post", @form.action)
    assert_equal("post", @form.method_attr)
    assert_equal("multipart/form-data", @form.enctype)
  end

  def test_elements_collection
    assert_equal(3, @form.elements.size)
  end

  def test_length
    assert_equal(3, @form.length)
  end

  def test_submit_does_not_fire_event
    # Spec: form.submit() bypasses the submit event (and constraint
    # validation). Use requestSubmit() for user-style submission.
    fired = false
    @form.add_event_listener("submit") { fired = true }
    @form.submit
    refute(fired)
  end

  def test_request_submit_fires_event
    fired = false
    @form.add_event_listener("submit") { fired = true }
    @form.request_submit
    assert(fired)
  end

  def test_reset_fires_event
    fired = false
    @form.add_event_listener("reset") { fired = true }
    @form.reset
    assert(fired)
  end

  def test_check_validity_returns_true
    assert_equal(true, @form.check_validity)
  end

  def test_no_validate_setter
    @form.no_validate = true
    assert(@form.has_attribute?("novalidate"))
  end
end

class TestHTMLInputElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form>
          <input id="i" name="email" type="email" placeholder="you@x.com" required>
          <label for="i">Email</label>
        </form>
      HTML
    )
    @doc = @win.document
    @input = @doc.get_element_by_id("i")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLInputElement, @input)
  end

  def test_type_default_text
    other = @doc.create_element("input")
    assert_equal("text", other.type)
  end

  def test_type_accessor
    assert_equal("email", @input.type)
    @input.type = "text"
    assert_equal("text", @input.type)
  end

  def test_reflected_string_attrs
    assert_equal("email", @input.name)
    assert_equal("you@x.com", @input.placeholder)
  end

  def test_form_back_ref
    refute_nil(@input.form)
    assert_equal("FORM", @input.form.tag_name)
  end

  def test_labels_collection
    labels = @input.labels
    assert_equal(1, labels.size)
    assert_equal("LABEL", labels.first.tag_name)
  end

  def test_required_reflected
    assert_equal(true, @input[:required])
  end

  def test_validity_full_check
    # Initially required + empty value → invalid.
    refute(@input.check_validity)
    @input[:value] = "user@example.com"
    assert(@input.check_validity)
    assert_nil(@input.set_custom_validity("bad"))
    # custom error makes it invalid again
    refute(@input.check_validity)
  end

  def test_select_stub_does_not_crash
    assert_nil(@input.select)
    assert_nil(@input.set_selection_range(0, 3))
  end
end

class TestHTMLButtonElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<form><button id='b' name='go'>Go</button></form>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLButtonElement, @btn)
  end

  def test_type_defaults_to_submit
    assert_equal("submit", @btn.type)
  end

  def test_type_set_to_button
    @btn.type = "button"
    assert_equal("button", @btn.type)
  end

  def test_invalid_type_falls_back_to_submit
    @btn.set_attribute("type", "weird")
    assert_equal("submit", @btn.type)
  end

  def test_form_back_ref
    refute_nil(@btn.form)
    assert_equal("FORM", @btn.form.tag_name)
  end

  def test_form_attributes
    @btn.set_attribute("formaction", "/x")
    @btn.set_attribute("formmethod", "post")
    assert_equal("/x", @btn[:formAction])
    assert_equal("post", @btn[:formMethod])
  end
end

class TestHTMLImageElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<img id='i' src='/cat.png' alt='cat' width='100' height='80'>")
    @doc = @win.document
    @img = @doc.get_element_by_id("i")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLImageElement, @img)
  end

  def test_reflected_attrs
    assert_equal("/cat.png", @img.src)
    assert_equal("cat", @img.alt)
    assert_equal(100, @img.width)
    assert_equal(80, @img.height)
  end

  def test_static_no_loader
    assert_equal(0, @img.natural_width)
    assert_equal(0, @img.natural_height)
    assert_equal(true, @img.complete)
    assert_equal("/cat.png", @img.current_src)
  end

  def test_setters_round_trip
    @img.src = "/dog.png"
    @img.width = 200
    assert_equal("/dog.png", @img.src)
    assert_equal(200, @img.width)
  end
end

class TestHTMLScriptElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<script id='s' src='/main.js' type='module' async defer></script>")
    @doc = @win.document
    @script = @doc.get_element_by_id("s")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLScriptElement, @script)
  end

  def test_reflected_attrs
    assert_equal("/main.js", @script.src)
    assert_equal("module", @script.type)
    assert_equal(true, @script.async)
    assert_equal(true, @script.defer)
  end

  def test_text_aliases_text_content
    @script.text = "console.log('hi')"
    assert_equal("console.log('hi')", @script.text_content)
  end

  def test_async_setter_round_trip
    @script.async = false
    refute(@script.has_attribute?("async"))
    @script.async = true
    assert(@script.has_attribute?("async"))
  end
end

class TestHTMLLinkElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<link id='l' href='/main.css' rel='stylesheet' type='text/css' media='screen'>")
    @doc = @win.document
    @link = @doc.get_element_by_id("l")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLLinkElement, @link)
  end

  def test_reflected_attrs
    assert_equal("/main.css", @link.href)
    assert_equal("stylesheet", @link.rel)
    assert_equal("text/css", @link.type)
    assert_equal("screen", @link.media)
  end
end

class TestHTMLSelectElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <select id="s" name="lang">
          <option value="ja">Japanese</option>
          <option value="en" selected>English</option>
          <option value="fr">French</option>
        </select>
      HTML
    )
    @doc = @win.document
    @sel = @doc.get_element_by_id("s")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLSelectElement, @sel)
  end

  def test_options_collection
    assert_equal(3, @sel.options.size)
    assert_equal(3, @sel.length)
  end

  def test_value_returns_selected_option_value
    assert_equal("en", @sel.value)
  end

  def test_selected_index
    assert_equal(1, @sel.selected_index)
  end

  def test_value_setter_selects_option
    @sel.value = "fr"
    assert_equal("fr", @sel.value)
    assert_equal(2, @sel.selected_index)
  end

  def test_selected_index_setter
    @sel.selected_index = 0
    assert_equal("ja", @sel.value)
  end

  def test_name_accessor
    assert_equal("lang", @sel.name)
  end
end

class TestGenericElementForUnknownTag < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='d'></div><my-widget id='w'></my-widget>")
    @doc = @win.document
  end

  def test_div_stays_plain_element
    el = @doc.get_element_by_id("d")
    assert_kind_of(Dommy::Element, el)
    refute_kind_of(Dommy::HTMLAnchorElement, el)
  end

  def test_unknown_custom_tag_stays_plain_element
    el = @doc.get_element_by_id("w")
    assert_kind_of(Dommy::Element, el)
  end
end
