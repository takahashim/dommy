# frozen_string_literal: true

require "json"
require_relative "test_helper"

# An element answers a WebIDL member only when its own interface chain has
# it — on the bridge and in Ruby alike. lean4-dom finding 57 was a member
# (dataset) Ruby gave every element though the IDL gives it to three
# interfaces; this checks every element class against the specs' own IDL
# for that shape, in both directions of the bridge.
#
# A member counts as "answered" on the bridge when `__js_get__` returns
# something other than ABSENT (an attribute) or `js_method_names` lists it
# (an operation), and in Ruby when the element responds to the member's
# snake_case name. The Ruby side is asked only about members of the node
# interfaces, so a Ruby convenience that happens to share a name with,
# say, Window's `document` is not taken for one, nor is a method every Ruby
# object has (`hash`, `method`). SVG elements are left out until the
# fixture carries SVG 2's IDL.
class TestInterfaceMembersPerElement < Minitest::Test
  IDL = JSON.parse(File.read(File.join(__dir__, "fixtures/webidl/interfaces.json")))["interfaces"]
  MATHML = "http://www.w3.org/1998/Math/MathML"

  # The interface and its inherited ones, as the IDL chains them.
  def self.chain(name)
    record = IDL[name]
    return [name] unless record

    [name] + (record["inherits"] ? chain(record["inherits"]) : [])
  end

  def self.members(names) = names.flat_map { |n| (IDL.dig(n, "members") || []).map { |m| m["name"] } }.compact

  # MathML Core's MathMLElement is not in the fixture: it is an Element with
  # HTML's HTMLOrSVGOrMathMLElement and CSSOM's ElementCSSInlineStyle.
  MATHML_MIXINS = %w[HTMLOrSVGOrMathMLElement ElementCSSInlineStyle].freeze
  MATHML_MEMBERS = IDL["HTMLElement"]["members"].select { |m| MATHML_MIXINS.include?(m["mixin"]) }.map { |m| m["name"] }

  def self.candidates(records)
    records.flat_map { |r| (r["members"] || []).reject { |m| m["static"] || m["kind"] == "const" } }
      .map { |m| [m["name"], m["kind"]] }.uniq.reject { |name, _| name.nil? || name.start_with?("on") }
  end

  BRIDGE_CANDIDATES = candidates(IDL.values)
  NODE_CANDIDATES = candidates(IDL.select { |name, _| chain(name).include?("Node") }.values)

  def setup
    @doc = Dommy.parse("").document
  end

  def elements
    cases = {
      "Element (no namespace)" => @doc.create_element_ns(nil, "x"),
      "Element (urn:x)" => @doc.create_element_ns("urn:x", "x"),
      "MathMLElement" => @doc.create_element_ns(MATHML, "mi"),
    }
    Dommy::HTML_ELEMENT_CLASSES.each { |tag, klass| cases["#{klass.name.split("::").last} <#{tag}>"] ||= @doc.create_element(tag) }
    cases
  end

  def allowed(element)
    chain = Dommy::Js::DomInterfaces.info(element)["chain"].flat_map { |name| self.class.chain(name) }.uniq
    names = self.class.members(chain)
    element.is_a?(Dommy::MathMLElement) ? names + MATHML_MEMBERS : names
  end

  def answered_on_bridge?(element, name, kind)
    return element.class.js_method_names.include?(name) if kind == "operation"

    !element.__js_get__(name).equal?(Dommy::Bridge::ABSENT)
  end

  def snake(name) = name.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase

  def test_an_element_answers_only_its_interfaces_members
    extra = elements.filter_map do |label, element|
      allowed = allowed(element)
      bridge = BRIDGE_CANDIDATES.reject { |name, _| allowed.include?(name) }
        .select { |name, kind| answered_on_bridge?(element, name, kind) }.map(&:first)
      ruby = NODE_CANDIDATES.reject { |name, _| allowed.include?(name) || Object.method_defined?(snake(name)) }
        .select { |name, _| element.respond_to?(snake(name)) }.map(&:first)
      next if bridge.empty? && ruby.empty?

      "#{label}: bridge #{bridge.sort} ruby #{ruby.sort}"
    end
    assert_empty extra, "members answered outside the element's own interfaces"
  end
end
