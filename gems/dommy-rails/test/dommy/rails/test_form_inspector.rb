require "test_helper"

class TestFormInspector < Minitest::Test
  include Dommy::TestHelpers

  def test_matches_form_with_action
    html = '<form action="/articles" method="post"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    assert Dommy::Rails::FormInspector.matches?(doc, action: "/articles")
  end

  def test_matches_form_with_method_override
    html = '<form action="/articles/1" method="post"><input type="hidden" name="_method" value="patch"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    assert Dommy::Rails::FormInspector.matches?(doc, action: "/articles/1", method: :patch)
    refute Dommy::Rails::FormInspector.matches?(doc, action: "/articles/1", method: :post)
  end

  def test_does_not_match_when_form_missing
    html = '<div>No form here</div>'
    doc = parse_html(html)
    refute Dommy::Rails::FormInspector.matches?(doc, action: "/articles")
  end

  def test_matches_form_with_model
    html = '<form action="/articles" method="post"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    assert Dommy::Rails::FormInspector.matches?(doc, model: stub_model("article"))
    refute Dommy::Rails::FormInspector.matches?(doc, model: stub_model("comment"))
  end

  def test_matches_form_with_model_responding_to_to_model
    html = '<form action="/articles" method="post"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    decorated = Struct.new(:to_model).new(stub_model("article"))
    assert Dommy::Rails::FormInspector.matches?(doc, model: decorated)
  end

  def test_rejects_model_without_active_model_interface
    html = '<form action="/articles" method="post"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    error = assert_raises(ArgumentError) do
      Dommy::Rails::FormInspector.matches?(doc, model: Object.new)
    end
    assert_includes error.message, "model_name"
  end

  private

  # Mimics the ActiveModel::Naming surface FormInspector relies on
  # (model.model_name.param_key) without depending on ActiveModel.
  def stub_model(param_key)
    Struct.new(:model_name).new(Struct.new(:param_key).new(param_key))
  end
end
