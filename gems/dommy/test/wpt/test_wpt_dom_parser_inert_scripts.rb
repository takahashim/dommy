# frozen_string_literal: true

require_relative "../test_helper"

# DOMParser parses with scripting (or XML scripting support) disabled, so
# every script it makes is "already started" and never runs — not when moved
# into a document that runs scripts, and not as a clone, since the HTML
# cloning steps copy the flag (for importNode as for cloneNode).
#
# WPT: domparsing/DOMParser-parseFromString-xml-scripting-support-disabled.html
# Spec: https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-domparser-parsefromstring
class TestWPTDOMParserInertScripts < Minitest::Test
  XHTML_SOURCE = "<html xmlns='http://www.w3.org/1999/xhtml'><body><script>x</script></body></html>"

  def setup
    @win = Dommy::Window.new
    @doc = @win.document
    @parser = Dommy::DOMParser.new(@win)
  end

  def started?(script)
    script.__internal_cloning_state__ == {already_started: true}
  end

  def xhtml_script
    @parser.parse_from_string(XHTML_SOURCE, "application/xhtml+xml")
      .get_elements_by_tag_name_ns(Dommy::Internal::Namespaces::HTML, "script").to_a.first
  end

  def test_parsed_scripts_are_already_started
    html_script = @parser.parse_from_string("<div><script>x</script></div>", "text/html").query_selector("script")
    assert(started?(html_script))
    assert_kind_of(Dommy::HTMLScriptElement, xhtml_script)
    assert(started?(xhtml_script))
  end

  def test_the_flag_survives_adopt_clone_and_import
    assert(started?(@doc.adopt_node(xhtml_script)))
    assert(started?(xhtml_script.clone_node(true)))
    assert(started?(@doc.import_node(xhtml_script, true)))
  end

  def test_a_script_created_by_script_is_not_started
    refute(started?(@doc.create_element("script")))
    assert_nil(@doc.import_node(@doc.create_element("script"), true).__internal_cloning_state__)
  end
end
