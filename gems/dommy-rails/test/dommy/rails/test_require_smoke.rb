require "test_helper"

class TestRequireSmoke < Minitest::Test
  include Dommy::TestHelpers

  def test_form_inspector_works_after_requiring_dommy_rails
    document = parse_html('<form action="/articles" method="post"></form>')

    assert Dommy::Rails::FormInspector.matches?(document, action: "/articles")
  end
end
