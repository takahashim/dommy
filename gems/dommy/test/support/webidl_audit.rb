# frozen_string_literal: true

require "json"
require_relative "js_surface"

# Compares Dommy's JS-visible surface against the WebIDL the specs themselves
# declare — `test/fixtures/webidl/interfaces.json`, distilled by
# `script/build_webidl_fixture.js` from a web-platform-tests checkout's
# `interfaces/*.idl`.
#
# This is the spec-conformance check that needs no browser and no JS engine:
# every interface name, inheritance edge, constant, attribute and operation is
# read statically (see JsSurface), so it runs in the plain `rake test` suite.
#
# Dommy is deliberately not a complete browser, so the audit is a RATCHET rather
# than a wall: what it cannot find is recorded in `gaps.json`, and the test
# asserts the current gaps EQUAL the recorded ones. Implementing something fails
# the test until the entry is removed; losing something fails it too.
module WebIdlAudit
  FIXTURE_DIR = File.expand_path("../fixtures/webidl", __dir__)
  INTERFACES_PATH = File.join(FIXTURE_DIR, "interfaces.json")
  GAPS_PATH = File.join(FIXTURE_DIR, "gaps.json")
  HOST_RUNTIME_PATH = File.expand_path("../../lib/dommy/js/host_runtime.js", __dir__)

  # Interfaces Dommy models without a Ruby class of the same name: mixins it
  # folds into its node classes, and the CSSOM rule interfaces it backs with one
  # polymorphic class. The value is the class whose surface answers for them.
  REPRESENTATIVES = {
    "Node" => "Element",
    "EventTarget" => "Element",
    "XMLDocument" => "Document",
    "StyleSheet" => "CSSStyleSheet",
    "CSSStyleRule" => "CSSRule",
    "CSSGroupingRule" => "CSSRule",
    "CSSConditionRule" => "CSSRule",
    "CSSMediaRule" => "CSSRule",
    "CSSSupportsRule" => "CSSRule",
    "CSSImportRule" => "CSSRule",
    "CSSFontFaceRule" => "CSSRule",
    "CSSPageRule" => "CSSRule",
    "CSSKeyframesRule" => "CSSRule",
    "CSSKeyframeRule" => "CSSRule"
  }.freeze

  # Namespaces holding Dommy's own plumbing, whose class basenames collide with
  # real interface names (Internal::XmlSerialization::Attr is not `Attr`).
  PRIVATE_NAMESPACES = ["Dommy::Internal::", "Dommy::Js::", "Dommy::Bridge::", "Dommy::Backend::"].freeze

  module_function

  def data
    @data ||= JSON.parse(File.read(INTERFACES_PATH))
  end

  # Every interface the specs expose on a Window, which is the surface a Dommy
  # document is expected to present. Worker-only interfaces are out of scope.
  def window_interfaces
    @window_interfaces ||= data["interfaces"].select { |_, rec| Array(rec["exposed"]).include?("Window") }
  end

  # The IDL inheritance chain, most-derived first — the shape
  # DomInterfaces::BASE_CHAINS entries and #chain_for results must have.
  def idl_chain(name)
    chain = []
    current = name
    while current && data["interfaces"][current]
      chain << current
      current = data["interfaces"][current]["inherits"]
    end
    chain << current if current # a base declared in a spec outside the fixture
    chain
  end

  def constants_of(name)
    window_interfaces.fetch(name, {"members" => []})["members"]
      .select { |m| m["kind"] == "const" }
      .to_h { |m| [m["name"], m["value"]] }
  end

  # Interface name -> the Dommy class carrying its bridge surface. Built by
  # inverting DomInterfaces.name_for over every loaded class, preferring a
  # top-level `Dommy::X` over a nested helper that happens to share a basename.
  def class_index
    @class_index ||= begin
      index = {}
      ObjectSpace.each_object(Class) do |klass|
        name = klass.name
        next unless name&.start_with?("Dommy::")
        next if PRIVATE_NAMESPACES.any? { |prefix| name.start_with?(prefix) }

        interface = Dommy::Js::DomInterfaces.name_for(klass)
        next unless interface

        current = index[interface]
        index[interface] = klass if current.nil? || name.count(":") < current.name.to_s.count(":")
      end
      REPRESENTATIVES.each { |interface, basename| index[interface] = index[basename] if index[basename] }
      index
    end
  end

  def ruby_class_for(name)
    class_index[name]
  end

  # Interfaces the JS side seeds a constructor + prototype for, whether or not a
  # Ruby class of that name exists (the CSSOM rule interfaces, NodeFilter, …).
  def seeded_interfaces
    @seeded_interfaces ||= Dommy::Js::DomInterfaces::BASE_CHAINS.flatten.uniq
  end

  def seeded_chains
    @seeded_chains ||= Dommy::Js::DomInterfaces::BASE_CHAINS.each_with_object({}) do |chain, out|
      out[chain.first] ||= chain
    end
  end

  def known?(name)
    !ruby_class_for(name).nil? || seeded_interfaces.include?(name)
  end

  # Interfaces the specs expose on a Window that Dommy neither classes nor seeds.
  def missing_interfaces
    window_interfaces.keys.reject { |name| known?(name) }.sort
  end

  # Per-interface IDL members Dommy's bridge does not answer. Static members are
  # skipped: they live on the interface object, which Dommy seeds separately.
  def member_gaps
    window_interfaces.each_with_object({}) do |(name, rec), out|
      klass = ruby_class_for(name)
      next unless klass

      properties = JsSurface.js_properties(klass)
      operations = JsSurface.js_operations(klass)
      missing = rec["members"].filter_map do |member|
        next if member["static"]

        case member["kind"]
        when "attribute" then member["name"] unless properties.include?(member["name"])
        when "operation" then member["name"] unless operations.include?(member["name"])
        end
      end.uniq.sort
      out[name] = missing unless missing.empty?
    end
  end

  # --- host_runtime.js [Constant] tables -----------------------------------
  # The tables live in the JS host runtime (they are placed on the interface
  # object and its prototype there). Reading them back is a small anchored
  # parse; `constant_tables_parsed?` lets the suite fail loudly if the shape
  # this depends on is ever refactored away, rather than silently passing.

  def js_constant_tables
    @js_constant_tables ||= begin
      source = File.read(HOST_RUNTIME_PATH)
      groups = {}
      source.scan(/const (\w+_CONSTANTS) = \{/) do |(group)|
        body = balanced_block(source, Regexp.last_match.end(0))
        groups[group] = body.scan(/\b([A-Z][A-Z0-9_]*)\s*:\s*([^,\n}]+)/).to_h
      end
      mapping = ""
      source.scan(/const INTERFACE_CONSTANTS = \{/) { mapping = balanced_block(source, Regexp.last_match.end(0)) }
      mapping.scan(/(\w+):\s*(\w+_CONSTANTS)/).to_h { |interface, group| [interface, groups.fetch(group, {})] }
    end
  end

  # The text of an object literal whose opening brace ends at `from`, matched by
  # counting braces (the tables are written both inline and across lines).
  def balanced_block(source, from)
    depth = 1
    index = from
    while index < source.length && depth.positive?
      case source[index]
      when "{" then depth += 1
      when "}" then depth -= 1
      end
      index += 1
    end
    source[from...(index - 1)].to_s
  end

  def constant_tables_parsed?
    tables = js_constant_tables
    tables.key?("Node") && tables["Node"]["ELEMENT_NODE"].to_s.strip == "1"
  end

  # --- recorded gaps --------------------------------------------------------

  def recorded_gaps
    @recorded_gaps ||= JSON.parse(File.read(GAPS_PATH))
  end

  def current_gaps
    {
      "missing_interfaces" => missing_interfaces,
      "missing_members" => member_gaps.sort.to_h
    }
  end

  # `RECORD_WEBIDL_GAPS=1 bundle exec rake test` rewrites the inventory after an
  # intentional change (or after regenerating interfaces.json from a newer WPT).
  def record_gaps!
    payload = {
      "README" => "Inventory of WebIDL members Dommy does not implement, recorded so " \
                  "test/test_webidl_conformance.rb can ratchet. Regenerate with " \
                  "RECORD_WEBIDL_GAPS=1 bundle exec rake test.",
      "wpt_commit" => data["wpt_commit"]
    }.merge(current_gaps)
    File.write(GAPS_PATH, JSON.pretty_generate(payload) + "\n")
  end
end
