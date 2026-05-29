# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestFormSubmission < Minitest::Test
  def config(respect_method_override: true)
    Dommy::Rack::Session::Config.new(
      default_host: "http://example.org",
      follow_redirects: true,
      max_redirects: 5,
      respect_method_override: respect_method_override,
      method_override_param: "_method",
      user_agent: "DommyRack",
      accept: "text/html"
    )
  end

  def form_from(html)
    Dommy.parse(html).document.query_selector("form")
  end

  def submit(html, submitter_selector: nil, **cfg)
    form = form_from(html)
    submitter = submitter_selector && form.query_selector(submitter_selector)
    Dommy::Rack::FormSubmission.new(form, submitter, config(**cfg)).submit!
  end

  # params is now an ordered Array of [name, value] pairs.
  def param(result, name)
    pair = result[:params].find { |k, _| k == name }
    pair && pair[1]
  end

  def has_param?(result, name)
    result[:params].any? { |k, _| k == name }
  end

  def test_collects_text_inputs
    result = submit(<<~HTML)
      <form action="/posts" method="post">
        <input type="text" name="title" value="Hello">
        <input type="hidden" name="token" value="abc">
      </form>
    HTML
    assert_equal "POST", result[:method]
    assert_equal "/posts", result[:url]
    assert_equal([["title", "Hello"], ["token", "abc"]], result[:params])
  end

  def test_excludes_disabled_and_nameless
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="text" name="a" value="1">
        <input type="text" name="b" value="2" disabled>
        <input type="text" value="3">
      </form>
    HTML
    assert_equal([["a", "1"]], result[:params])
  end

  def test_unchecked_checkbox_excluded_checked_included
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="checkbox" name="agree" value="yes" checked>
        <input type="checkbox" name="news" value="yes">
      </form>
    HTML
    assert_equal([["agree", "yes"]], result[:params])
  end

  def test_checkbox_default_value_on
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="checkbox" name="flag" checked>
      </form>
    HTML
    assert_equal([["flag", "on"]], result[:params])
  end

  def test_radio_selected_value
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="radio" name="size" value="s">
        <input type="radio" name="size" value="m" checked>
      </form>
    HTML
    assert_equal([["size", "m"]], result[:params])
  end

  def test_select_selected_option
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <select name="color">
          <option value="r">Red</option>
          <option value="g" selected>Green</option>
        </select>
      </form>
    HTML
    assert_equal([["color", "g"]], result[:params])
  end

  def test_textarea_value
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <textarea name="body">hello world</textarea>
      </form>
    HTML
    assert_equal([["body", "hello world"]], result[:params])
  end

  def test_submitter_name_value_included
    result = submit(<<~HTML, submitter_selector: "button[name='commit']")
      <form action="/x" method="post">
        <input type="text" name="a" value="1">
        <button type="submit" name="commit" value="Save">Save</button>
        <button type="submit" name="commit" value="Draft">Draft</button>
      </form>
    HTML
    assert_equal([["a", "1"], ["commit", "Save"]], result[:params])
  end

  def test_non_submitter_buttons_excluded
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="text" name="a" value="1">
        <button type="submit" name="commit" value="Save">Save</button>
      </form>
    HTML
    assert_equal([["a", "1"]], result[:params])
  end

  def test_get_form_strips_action_query
    result = submit(<<~HTML)
      <form action="/search?old=1" method="get">
        <input type="text" name="q" value="ruby">
      </form>
    HTML
    assert_equal "GET", result[:method]
    assert_equal "/search", result[:url]
    assert_equal([["q", "ruby"]], result[:params])
  end

  def test_method_override_to_patch
    result = submit(<<~HTML)
      <form action="/posts/1" method="post">
        <input type="hidden" name="_method" value="patch">
        <input type="text" name="title" value="Edit">
      </form>
    HTML
    assert_equal "PATCH", result[:method]
    refute has_param?(result, "_method")
    assert_equal([["title", "Edit"]], result[:params])
  end

  def test_method_override_disabled
    result = submit(<<~HTML, respect_method_override: false)
      <form action="/posts/1" method="post">
        <input type="hidden" name="_method" value="patch">
      </form>
    HTML
    assert_equal "POST", result[:method]
    assert_equal "patch", param(result, "_method")
  end

  def test_formaction_overrides_action
    result = submit(<<~HTML, submitter_selector: "button")
      <form action="/default" method="post">
        <button type="submit" formaction="/special">Go</button>
      </form>
    HTML
    assert_equal "/special", result[:url]
  end

  def test_collects_attached_file
    form = form_from(<<~HTML)
      <form action="/u" method="post" enctype="multipart/form-data">
        <input type="file" name="doc">
      </form>
    HTML
    file = Dommy::File.new(["hi"], "a.txt", "type" => "text/plain")
    form.query_selector("input[type='file']").__driver_set_files__([file])

    result = Dommy::Rack::FormSubmission.new(form, nil, config).submit!
    assert_same file, param(result, "doc")
  end

  def test_empty_file_input_keeps_name_with_empty_file
    form = form_from(<<~HTML)
      <form action="/u" method="post" enctype="multipart/form-data">
        <input type="file" name="doc">
      </form>
    HTML
    result = Dommy::Rack::FormSubmission.new(form, nil, config).submit!

    assert has_param?(result, "doc")
    assert_respond_to param(result, "doc"), :__dommy_bytes__
  end

  def test_collects_later_input_types
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="date" name="d" value="2026-05-29">
        <input type="time" name="t" value="13:30">
        <input type="month" name="m" value="2026-05">
        <input type="week" name="w" value="2026-W22">
        <input type="color" name="c" value="#ff0000">
        <input type="range" name="r" value="5">
        <input type="number" name="n" value="42">
      </form>
    HTML
    assert_equal(
      [["d", "2026-05-29"], ["t", "13:30"], ["m", "2026-05"], ["w", "2026-W22"],
       ["c", "#ff0000"], ["r", "5"], ["n", "42"]],
      result[:params]
    )
  end

  def test_reset_input_excluded
    result = submit(<<~HTML)
      <form action="/x" method="post">
        <input type="text" name="a" value="1">
        <input type="reset" name="rst" value="Clear">
      </form>
    HTML
    assert_equal([["a", "1"]], result[:params])
  end

  def test_image_submitter_sends_coordinates
    result = submit(<<~HTML, submitter_selector: "input[type='image']")
      <form action="/x" method="post">
        <input type="text" name="a" value="1">
        <input type="image" name="go" src="/btn.png" alt="Go">
      </form>
    HTML
    assert_equal([["a", "1"], ["go.x", "0"], ["go.y", "0"]], result[:params])
  end

  def test_image_submitter_without_name_uses_bare_coordinates
    result = submit(<<~HTML, submitter_selector: "input[type='image']")
      <form action="/x" method="post">
        <input type="image" src="/btn.png" alt="Go">
      </form>
    HTML
    assert_equal([["x", "0"], ["y", "0"]], result[:params])
  end

  def test_accept_charset_encodes_values
    result = submit(<<~HTML)
      <form action="/x" method="post" accept-charset="Shift_JIS">
        <input type="text" name="q" value="あ">
      </form>
    HTML
    assert_equal "あ".encode("Shift_JIS").b, param(result, "q")
  end

  def test_accept_charset_utf8_is_noop
    result = submit(<<~HTML)
      <form action="/x" method="post" accept-charset="UTF-8">
        <input type="text" name="q" value="hi">
      </form>
    HTML
    assert_equal "hi", param(result, "q")
  end
end
