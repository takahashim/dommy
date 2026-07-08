# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLOptionElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <select id="s">
          <option value="ja">Japanese</option>
          <option selected>English</option>
          <option value="fr" disabled>French</option>
        </select>
      HTML
    )
    @doc = @win.document
    @sel = @doc.get_element_by_id("s")
    @opts = @sel.options
  end

  def test_class_dispatch
    @opts.each { |o| assert_kind_of(Dommy::HTMLOptionElement, o) }
  end

  def test_value_uses_attribute_when_present
    assert_equal("ja", @opts[0].value)
  end

  def test_value_falls_back_to_text_when_absent
    assert_equal("English", @opts[1].value)
  end

  def test_label_falls_back_to_text
    assert_equal("Japanese", @opts[0].label)
  end

  def test_selected_reflects_attribute
    refute(@opts[0].selected)
    assert(@opts[1].selected)
  end

  def test_selected_setter
    @opts[0].selected = true
    assert(@opts[0].selected)
    @opts[0].selected = false
    refute(@opts[0].selected)
  end

  def test_disabled_reflects_attribute
    assert(@opts[2].disabled)
    refute(@opts[0].disabled)
  end

  def test_text_is_text_content
    assert_equal("Japanese", @opts[0].text)
    @opts[0].text = "JP"
    assert_equal("JP", @opts[0].text_content)
  end

  def test_index_returns_position_in_select
    assert_equal(0, @opts[0].index)
    assert_equal(1, @opts[1].index)
    assert_equal(2, @opts[2].index)
  end

  def test_form_back_ref_nil_outside_form
    assert_nil(@opts[0].form)
  end
end

class TestHTMLOptGroupElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <select>
          <optgroup id='g' label="Asia" disabled>
            <option>Japan</option>
          </optgroup>
        </select>
      HTML
    )
    @grp = @win.document.get_element_by_id("g")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLOptGroupElement, @grp)
  end

  def test_label_attr
    assert_equal("Asia", @grp.label)
  end

  def test_disabled_attr
    assert(@grp.disabled)
  end

  def test_label_setter
    @grp.label = "Europe"
    assert_equal("Europe", @grp.get_attribute("label"))
  end
end

class TestHTMLTextAreaElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
              <form>
                <textarea id="t" name="msg" placeholder="...type here" rows="5" cols="40" maxlength="200">Hello
        World</textarea>
                <label for="t">Message</label>
              </form>
      HTML
    )
    @ta = @win.document.get_element_by_id("t")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTextAreaElement, @ta)
  end

  def test_value_initial_from_text_content
    assert_match(/Hello.*World/m, @ta.value)
  end

  def test_value_set_round_trip
    @ta.value = "replaced"
    assert_equal("replaced", @ta.value)
    assert_equal("replaced", @ta.text_content)
  end

  def test_rows_cols_attrs
    assert_equal(5, @ta.rows)
    assert_equal(40, @ta.cols)
  end

  def test_rows_setter
    @ta.rows = 10
    assert_equal(10, @ta.rows)
  end

  def test_max_length_attr
    assert_equal(200, @ta.max_length)
  end

  def test_min_length_default_minus_one
    assert_equal(-1, @ta.min_length)
  end

  def test_text_length_matches_value_length
    assert_equal(@ta.value.length, @ta.text_length)
  end

  def test_name_and_placeholder
    assert_equal("msg", @ta.name)
    assert_equal("...type here", @ta.placeholder)
  end

  def test_type_constant_textarea
    assert_equal("textarea", @ta.type)
  end

  def test_form_back_ref
    refute_nil(@ta.form)
    assert_equal("FORM", @ta.form.tag_name)
  end

  def test_labels_collection
    labels = @ta.labels
    assert_equal(1, labels.size)
    assert_equal("LABEL", labels.first.tag_name)
  end

  def test_validity_stub
    refute_nil(@ta.validity)
    assert(@ta.check_validity)
  end

  def test_select_stubs
    assert_nil(@ta.select)
    assert_nil(@ta.set_selection_range(0, 5))
  end
end

class TestHTMLLabelElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form>
          <label id="l1" for="email">Email</label>
          <input id="email" name="email">
          <label id="l2">Nested<input id="nested" name="nested"></label>
        </form>
      HTML
    )
    @l1 = @win.document.get_element_by_id("l1")
    @l2 = @win.document.get_element_by_id("l2")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLLabelElement, @l1)
  end

  def test_html_for_attr
    assert_equal("email", @l1.html_for)
  end

  def test_control_via_for_attr
    target = @l1.control
    refute_nil(target)
    assert_equal("email", target.id)
  end

  def test_control_via_descendant_when_no_for
    target = @l2.control
    refute_nil(target)
    assert_equal("nested", target.id)
  end

  def test_form_back_ref
    refute_nil(@l1.form)
    assert_equal("FORM", @l1.form.tag_name)
  end

  def test_html_for_setter
    @l1.html_for = "other"
    assert_equal("other", @l1.get_attribute("for"))
  end
end

class TestHTMLFieldsetElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form>
          <fieldset id="f" name="addr" disabled>
            <legend>Address</legend>
            <input name="street">
            <input name="city">
          </fieldset>
        </form>
      HTML
    )
    @fs = @win.document.get_element_by_id("f")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLFieldSetElement, @fs)
  end

  def test_name_attr
    assert_equal("addr", @fs.name)
  end

  def test_disabled_attr
    assert(@fs.disabled)
  end

  def test_type_constant
    assert_equal("fieldset", @fs.type)
  end

  def test_form_back_ref
    refute_nil(@fs.form)
  end

  def test_elements_collection
    # Should include both inputs (legend is excluded from the list).
    assert_operator(@fs.elements.size, :>=, 2)
  end

  def test_validity_stub
    refute_nil(@fs.validity)
    assert(@fs.check_validity)
  end
end

class TestHTMLOutputElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form>
          <output id="o" name="result" for="a b">42</output>
        </form>
      HTML
    )
    @out = @win.document.get_element_by_id("o")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLOutputElement, @out)
  end

  def test_value_is_text_content
    assert_equal("42", @out.value)
  end

  def test_value_setter_writes_text
    @out.value = "100"
    assert_equal("100", @out.text_content)
  end

  def test_name_attr
    assert_equal("result", @out.name)
  end

  def test_html_for_tokens
    assert_equal(["a", "b"], @out.html_for_tokens)
  end

  def test_type_constant
    assert_equal("output", @out.type)
  end
end

class TestHTMLLegendElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <form>
          <fieldset>
            <legend id='lg'>Title</legend>
          </fieldset>
        </form>
      HTML
    )
    @lg = @win.document.get_element_by_id("lg")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLLegendElement, @lg)
  end

  def test_form_back_ref_through_fieldset
    refute_nil(@lg.form)
    assert_equal("FORM", @lg.form.tag_name)
  end
end

class TestHTMLSelectExtensions < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      <<~HTML
        <select id="s">
          <option value="ja">Japanese</option>
          <option value="en">English</option>
        </select>
      HTML
    )
    @doc = @win.document
    @sel = @doc.get_element_by_id("s")
  end

  def test_item_returns_option_at_index
    assert_equal("ja", @sel.item(0).value)
    assert_equal("en", @sel.item(1).value)
  end

  def test_add_appends_new_option
    fr = @doc.create_element("option")
    fr.set_attribute("value", "fr")
    fr.text_content = "French"
    @sel.add(fr)
    assert_equal(3, @sel.options.size)
    assert_equal("fr", @sel.options[-1].value)
  end

  def test_add_with_before_inserts_at_position
    fr = @doc.create_element("option")
    fr.set_attribute("value", "fr")
    @sel.add(fr, @sel.options[1])
    assert_equal("fr", @sel.options[1].value)
  end

  def test_type_select_one_when_not_multiple
    assert_equal("select-one", @sel.type)
  end

  def test_type_select_multiple_when_multiple
    @sel.multiple = true
    assert_equal("select-multiple", @sel.type)
  end

  def test_validity_stub
    refute_nil(@sel.validity)
    assert(@sel.check_validity)
  end
end

class TestValidityState < Minitest::Test
  def test_valid_is_true
    v = Dommy::ValidityState.new
    assert_equal(true, v.__js_get__("valid"))
  end

  def test_flags_are_false
    v = Dommy::ValidityState.new
    Dommy::ValidityState::FLAGS.each do |flag|
      assert_equal(false, v.__js_get__(flag), flag)
    end
  end
end

# WHATWG value sanitization + maxLength/minLength + files (bugs found via WPT).
class TestHTMLInputElementSanitization < Minitest::Test
  include DommyTestHelper

  def input(html)
    @win = make_window(html)
    @win.document.get_element_by_id("i")
  end

  def test_one_line_types_strip_newlines
    %w[text search tel password url].each do |type|
      el = input("<input id='i' type='#{type}'>")
      el.__js_set__("value", "a\nb\r\nc")
      assert_equal("abc", el.__js_get__("value"), "type=#{type} strips newlines")
    end
  end

  def test_multiline_textarea_keeps_newlines
    el = input("<textarea id='i'></textarea>")
    el.__js_set__("value", "a\nb")
    assert_equal("a\nb", el.__js_get__("value"))
  end

  def test_maxlength_minlength_default_to_minus_one
    el = input("<input id='i' type='text'>")
    assert_equal(-1, el.__js_get__("maxLength"))
    assert_equal(-1, el.__js_get__("minLength"))
  end

  def test_maxlength_reflects
    el = input("<input id='i' maxlength='7' minlength='2'>")
    assert_equal(7, el.__js_get__("maxLength"))
    assert_equal(2, el.__js_get__("minLength"))
    el.__js_set__("maxLength", 5)
    assert_equal("5", el.get_attribute("maxlength"))
    assert_raises(Dommy::DOMException::IndexSizeError) { el.__js_set__("maxLength", -1) }
  end

  def test_files_is_null_for_non_file_types
    assert_nil(input("<input id='i' type='text'>").__js_get__("files"))
    assert_instance_of(Dommy::FileList, input("<input id='i' type='file'>").__js_get__("files"))
  end
end
