# frozen_string_literal: true

require_relative "test_helper"

# Module specifiers resolve as HTML's "resolve a module specifier" does: a
# URL-like one by the URL parser, a bare one through the import map.
class TestModuleLoader < Minitest::Test
  BASE = "http://a.test/dir/page.html"

  def loader(import_map = "")
    resources = Dommy::Resources.static("/dir/a%20b.js" => {"body" => "export default 1", "content_type" => "text/javascript"})
    Dommy::Js::ModuleLoader.new(resources, Dommy::Js::ImportMap.parse(import_map), base_url: BASE)
  end

  def test_url_like_specifiers_are_urls
    l = loader
    assert_equal("http://a.test/dir/a%20b.js", l.resolve_url("./a b.js"))
    assert_equal("http://a.test/%E6%97%A5.js", l.resolve_url("/\u65E5.js"))
    assert_equal("http://a.test/x.js", l.resolve_url("../x.js"))
    assert_equal("http://b.test/u.js", l.resolve_url("HTTP://B.TEST/u.js"))
    assert_equal("data:text/javascript,export default 2", l.resolve_url("data:text/javascript,export default 2"))
  end

  def test_a_relative_specifier_resolves_against_the_importer
    assert_equal("http://c.test/lib/b.js", loader.resolve_url("./b.js", "http://c.test/lib/a.js"))
  end

  def test_bare_specifiers_go_through_the_import_map
    l = loader('{"imports": {"lodash": "/vendor/lodash.js"}}')
    assert_equal("http://a.test/vendor/lodash.js", l.resolve_url("lodash"))
    assert_nil(l.resolve_url("react"))
  end

  def test_a_data_url_module_is_its_payload
    assert_equal({code: "export default 2", as: "data:text/javascript,export default 2"},
                 loader.call("data:text/javascript,export default 2"))
    assert_equal({code: "export default 1", as: "http://a.test/dir/a%20b.js"}, loader.call("./a b.js"))
  end
end
