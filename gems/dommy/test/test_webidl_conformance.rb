# frozen_string_literal: true

require_relative "test_helper"
require "support/webidl_audit"

# Spec conformance measured against the WebIDL the specs publish, rather than
# against a browser: `test/fixtures/webidl/interfaces.json` is distilled by
# `script/build_webidl_fixture.js` from a web-platform-tests checkout's
# `interfaces/*.idl` (which WPT extracts from the spec sources).
#
# Nothing here needs a JS engine or a browser — the surface is read statically
# off the bridge classes — so the audit runs in the ordinary suite and keeps
# working when the JS bindings are not installed.
#
# Two levels of strictness:
#
#   * Inheritance chains and [Constant]s must match the IDL exactly. They are
#     cheap to get right, and getting them wrong breaks `instanceof` and
#     `CSSRule.STYLE_RULE`-style branching in real libraries.
#   * Interfaces and members Dommy does not implement are recorded in
#     `gaps.json`, and the test asserts the CURRENT gaps equal the recorded
#     ones. Dommy is not a complete browser, so the inventory is the point:
#     implementing something fails until its entry is removed, and losing
#     something fails too.
#
# Regenerate after an intentional change, or after refreshing interfaces.json
# from a newer WPT:
#
#     RECORD_WEBIDL_GAPS=1 bundle exec rake test
#
# JsSurface reads the dispatch tables through RubyVM::AbstractSyntaxTree, so the
# member half is MRI-only.
class TestWebIdlInheritance < Minitest::Test
  def setup
    # Loading a Window pulls in every bridge class, so the class index below
    # sees the whole surface rather than whatever happened to be autoloaded.
    Dommy::Window.new
  end

  def test_the_fixture_covers_the_specs_dommy_models
    assert_operator WebIdlAudit.window_interfaces.size, :>, 150,
      "interfaces.json looks truncated — regenerate it with script/build_webidl_fixture.js"
    assert_equal "EventTarget", WebIdlAudit.data["interfaces"]["Node"]["inherits"]
  end

  # Every seeded prototype chain must be the IDL's own inheritance chain.
  # A wrong one is directly observable: `reader instanceof EventTarget`,
  # `file instanceof Blob`, `range instanceof AbstractRange`.
  def test_seeded_chains_match_the_idl_inheritance
    mismatched = WebIdlAudit.seeded_chains.filter_map do |name, chain|
      next unless WebIdlAudit.data["interfaces"].key?(name)

      want = WebIdlAudit.idl_chain(name)
      "#{name}: seeded #{chain.join(" > ")} but IDL says #{want.join(" > ")}" unless chain == want
    end
    assert_empty mismatched
  end

  # Whatever a real instance reports has to agree with the seeded chain, or the
  # eagerly created prototype and the one an instance lands on diverge.
  def test_derived_chains_agree_with_the_idl
    window = Dommy.parse("<p id='p'>x</p>")
    document = window.document
    samples = [
      document.get_element_by_id("p"),
      document,
      document.get_element_by_id("p").first_child,
      document.create_range,
      document.create_document_fragment,
      Dommy::Event.new("x"),
      Dommy::File.new([""], "a.txt"),
      Dommy::FileReader.new(window)
    ]
    samples.each do |object|
      chain = Dommy::Js::DomInterfaces.chain_for(object)
      assert_equal WebIdlAudit.idl_chain(chain.first), chain,
        "#{chain.first} instance chain"
    end
  end

  # FileReader, XMLHttpRequest, Worker and friends inherit EventTarget in the
  # IDL, but Dommy models EventTarget as a mixin rather than a superclass, so
  # the chain has to append it explicitly.
  def test_a_non_node_event_target_reports_EventTarget_in_its_chain
    window = Dommy::Window.new
    reader = Dommy::FileReader.new(window)
    assert_equal %w[FileReader EventTarget], Dommy::Js::DomInterfaces.chain_for(reader)
  end
end

# WebIDL [Constant]s live on both the interface object and its prototype. Their
# values are part of the API contract (`rule.type === CSSRule.STYLE_RULE`).
class TestWebIdlConstants < Minitest::Test
  def setup
    Dommy::Window.new
  end

  # The tables are read back out of host_runtime.js; if that shape is ever
  # refactored this check fails rather than the audit silently passing.
  def test_the_constant_tables_are_readable
    assert WebIdlAudit.constant_tables_parsed?,
      "could not read INTERFACE_CONSTANTS out of host_runtime.js — update WebIdlAudit"
  end

  def test_every_declared_interfaces_constants_match_the_idl
    problems = []
    WebIdlAudit.js_constant_tables.each do |interface, table|
      idl = WebIdlAudit.constants_of(interface)
      next if idl.empty? # an interface whose spec is outside the fixture

      missing = idl.keys - table.keys
      extra = table.keys - idl.keys
      wrong = idl.filter_map do |name, value|
        got = table[name]
        next unless got

        "#{name}=#{got} (IDL #{value})" unless Integer(got, exception: false) == Integer(value, exception: false)
      end
      problems << "#{interface}: missing #{missing}" unless missing.empty?
      problems << "#{interface}: not in the IDL #{extra}" unless extra.empty?
      problems << "#{interface}: wrong values #{wrong}" unless wrong.empty?
    end
    assert_empty problems
  end

  # An interface that HAS constants in the IDL but no table at all is a silent
  # gap, so it must be accounted for in the recorded inventory.
  def test_interfaces_with_idl_constants_are_covered_or_recorded
    uncovered = WebIdlAudit.window_interfaces.filter_map do |name, rec|
      next if rec["members"].none? { |m| m["kind"] == "const" }
      next if WebIdlAudit.js_constant_tables.key?(name)

      name
    end
    assert_equal WebIdlAudit.recorded_gaps["missing_interfaces"] & uncovered, uncovered,
      "these interfaces declare IDL constants Dommy exposes nowhere, and are not " \
      "recorded as missing: #{uncovered - WebIdlAudit.recorded_gaps["missing_interfaces"]}"
  end
end

# The member audit walks the bridge dispatch tables, so it needs MRI's AST.
if JsSurface.available?
  class TestWebIdlMemberInventory < Minitest::Test
    def setup
      Dommy::Window.new
      WebIdlAudit.record_gaps! if ENV["RECORD_WEBIDL_GAPS"]
    end

    def test_the_surface_reader_finds_a_known_member_set
      # Self-check: if JsSurface ever stops seeing the dispatch arms it would
      # report every member as missing, and the ratchet below would "pass" only
      # because gaps.json had been re-recorded from the same broken reading.
      properties = JsSurface.js_properties(Dommy::Element)
      assert_includes properties, "tagName"
      assert_includes properties, "id"
      assert_includes JsSurface.js_operations(Dommy::Element), "querySelectorAll"
      assert_includes JsSurface.js_properties(Dommy::HTMLImageElement), "alt",
        "reflected IDL attributes must be part of the surface"
    end

    def test_missing_interfaces_match_the_recorded_inventory
      assert_equal WebIdlAudit.recorded_gaps["missing_interfaces"],
                   WebIdlAudit.missing_interfaces,
                   "interfaces Dommy exposes changed; re-record with RECORD_WEBIDL_GAPS=1"
    end

    def test_missing_members_match_the_recorded_inventory
      recorded = WebIdlAudit.recorded_gaps["missing_members"]
      current = WebIdlAudit.member_gaps
      (recorded.keys | current.keys).sort.each do |interface|
        assert_equal recorded.fetch(interface, []), current.fetch(interface, []),
          "#{interface}: IDL members Dommy answers changed; " \
          "re-record with RECORD_WEBIDL_GAPS=1"
      end
    end
  end
end
