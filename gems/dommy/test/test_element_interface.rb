# frozen_string_literal: true

require_relative "test_helper"

# HTML "element interface": the interface an HTML-namespace element gets from
# its local name. WPT html/semantics/interfaces.html.
class TestElementInterface < Minitest::Test
  def interface_of(name)
    Dommy::Js::DomInterfaces.name_for(Dommy.parse("<p></p>").document.create_element(name).class)
  end

  def test_elements_without_an_interface_of_their_own_are_html_elements
    %w[b section article nav abbr summary wbr acronym center tt].each do |name|
      assert_equal "HTMLElement", interface_of(name), name
    end
  end

  def test_listing_and_xmp_are_pre_elements
    assert_equal "HTMLPreElement", interface_of("listing")
    assert_equal "HTMLPreElement", interface_of("xmp")
  end

  def test_unknown_and_obsolete_names_are_unknown_elements
    %w[applet blink keygen foo].each do |name|
      assert_equal "HTMLUnknownElement", interface_of(name), name
    end
    assert_equal "HTMLElement", interface_of("x-foo")
  end
end
