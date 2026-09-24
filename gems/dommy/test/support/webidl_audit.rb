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
  WEBIDL_TABLES_PATH = File.expand_path("../../lib/dommy/js/webidl_tables.js", __dir__)

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

  # --- reflected IDL attributes (HTML §2.6.1) -------------------------------
  # The specs' own IDL says how each attribute reflects — [Reflect] /
  # [ReflectURL] / [ReflectSetter], plus the numeric parameters — and the type it
  # reflects AS is the IDL type. Dommy declares the same thing with reflect_string
  # / reflect_url / reflect_boolean / ..., so the two can be compared: an
  # attribute Dommy answers but reflects with the wrong algorithm (a URL returned
  # verbatim, an `unsigned long` read with String#to_i) shows up here rather than
  # waiting for a browser to disagree.

  # The §2.6.1 type an IDL type reflects as, for the plain [Reflect] shapes.
  REFLECT_TYPE_FOR_IDL = {
    "DOMString" => :string,
    "USVString" => :string,
    "DOMString?" => :nullable_string,
    "boolean" => :boolean,
    "long" => :long,
    "unsigned long" => :ulong,
    "double" => :double,
    "DOMTokenList" => :token_list,
    "Element?" => :element_ref,
    "FrozenArray<Element>?" => :element_refs
  }.freeze

  # How the member should be declared: the shape when the spec names one
  # ([ReflectURL] is a URL whatever its IDL type says; [ReflectSetter] means the
  # getter is prose), otherwise the type it reflects as.
  def expected_reflect_type(member)
    case member["reflect"]["shape"]
    when "url" then :url
    when "setter" then :setter_only
    else REFLECT_TYPE_FOR_IDL[member["type"]]
    end
  end

  # The content attribute a reflecting member mirrors: [Reflect="x"] when the
  # spec names one, else the IDL name lowercased (HTML's content attributes are
  # ASCII-lowercase).
  def expected_reflect_attr(member)
    member["reflect"]["attr"] || member["name"].downcase
  end

  # Reflections Dommy gets wrong or writes by hand, as
  # "Interface.attribute" => "what it is (what it should be)". An attribute Dommy
  # does not implement at all is a member gap, not a reflection gap, and is left
  # to `member_gaps`.
  def reflect_gaps
    out = {}
    data["interfaces"].each do |name, record|
      klass = ruby_class_for(name)
      next unless klass.respond_to?(:reflect_specs)

      declared = klass.reflect_specs
      record["members"].each do |member|
        next unless member["kind"] == "attribute" && member["reflect"]

        expected = expected_reflect_type(member)
        next unless expected

        gap = reflect_gap_for(klass, declared[member["name"]], member, expected)
        out["#{name}.#{member['name']}"] = gap if gap
      end
    end
    out.sort.to_h
  end

  def reflect_gap_for(klass, spec, member, expected)
    if spec.nil?
      return nil unless answers?(klass, member["name"])

      "hand-written (expected #{expected})"
    elsif spec[:type] != expected
      "declared #{spec[:type]} (expected #{expected})"
    elsif !spec[:attr].casecmp?(expected_reflect_attr(member))
      "mirrors #{spec[:attr].inspect} (expected #{expected_reflect_attr(member).inspect})"
    end
  end

  # Whether Dommy answers this JS property name at all, by any route.
  def answers?(klass, js_name)
    klass.reflected_property_map.key?(js_name) || JsSurface.js_properties(klass).include?(js_name)
  end

  # --- the JS half's own tables against the IDL -----------------------------
  # webidl_tables.js carries three tables the IDL could have told it: which
  # operations return undefined (so a host's "nothing" crosses as undefined
  # rather than null), how many arguments each operation requires (its `length`),
  # and which interfaces are legacy platform objects with indices, names, or an
  # `iterable<>`. Each is compared with what the specs declare.

  TABLES_PATH = File.expand_path("../../lib/dommy/js/webidl_tables.js", __dir__)

  def tables_source
    @tables_source ||= File.read(TABLES_PATH)
  end

  def js_name_set(constant)
    body = tables_source[/const #{constant} = new Set\(\[(.*?)\]\);/m, 1]
    raise "#{constant} is missing from webidl_tables.js" unless body

    body.scan(/"([^"]+)"/).flatten.to_set
  end

  # Operation name -> the interfaces that declare it, and of those, the ones
  # whose return type is `undefined`. An operation only belongs in a table keyed
  # by NAME when every interface agrees.
  def operation_returns
    @operation_returns ||= begin
      index = Hash.new { |h, k| h[k] = {declared: [], void: []} }
      data["interfaces"].each do |interface, record|
        record["members"].each do |member|
          next unless member["kind"] == "operation" && member["name"] && !member["static"]

          index[member["name"]][:declared] << interface
          index[member["name"]][:void] << interface if member["returns"] == "undefined"
        end
      end
      index
    end
  end

  # Where the JS half's VOID_METHODS disagrees with the IDL, per interface. The
  # table is keyed by operation NAME, so it can only be right for a name every
  # interface agrees on; a name whose return type differs between interfaces
  # (`replace` is undefined on Location, a boolean on DOMTokenList, a Promise on
  # CSSStyleSheet) needs the per-interface table beside it.
  #
  # Listed here means the bridge turns a null answer into undefined; absent
  # means it does not, and the Ruby method has to remember to return the
  # UNDEFINED sentinel itself for the page to see one.
  def void_gaps
    listed = js_name_set("VOID_METHODS")
    per_interface = js_interface_name_sets("INTERFACE_VOID_METHODS")
    gaps = {}
    each_implemented_operation do |interface, member|
      name = member["name"]
      void = member["returns"] == "undefined"
      guaranteed = (per_interface[interface] || Set.new).include?(name) || listed.include?(name)
      next if void == guaranteed

      gaps["#{interface}.#{name}"] =
        void ? "returns undefined, which the bridge does not guarantee" : "returns #{member['returns']}, but a null answer becomes undefined"
    end
    gaps.sort.to_h
  end

  # `{ Interface: ["a", "b"] }` tables in the JS half.
  def js_interface_name_sets(constant)
    body = tables_source[/const #{constant} = \{(.*?)\n  \};/m, 1].to_s
    body.scan(/(\w+):\s*\[([^\]]*)\]/).to_h do |interface, names|
      [interface, names.scan(/"([^"]+)"/).flatten.to_set]
    end
  end

  # The WebIDL `length` of each operation Dommy answers, against the table the
  # JS half stamps onto its stubs.
  def arity_gaps
    per_name = js_table("METHOD_ARITY")
    per_interface = js_interface_arity
    gaps = {}
    each_implemented_operation do |interface, member|
      name = member["name"]
      declared = (per_interface[interface] || {})[name] || per_name[name]
      next if declared.nil? || declared == member["required"]

      gaps["#{interface}.#{name}"] = "length #{declared} (IDL requires #{member['required']})"
    end
    gaps.sort.to_h
  end

  def js_table(constant)
    body = tables_source[/const #{constant} = \{(.*?)\n  \};/m, 1] or raise "#{constant} missing"
    body.scan(/(\w+):\s*(\d+)/).to_h { |name, value| [name, value.to_i] }
  end

  def js_interface_arity
    body = tables_source[/const INTERFACE_METHOD_ARITY = \{(.*?)\n  \};/m, 1].to_s
    body.scan(/(\w+):\s*\{([^}]*)\}/).to_h do |interface, members|
      [interface, members.scan(/(\w+):\s*(\d+)/).to_h { |name, value| [name, value.to_i] }]
    end
  end

  # Every operation an interface declares that Dommy answers.
  def each_implemented_operation
    data["interfaces"].each do |interface, record|
      klass = ruby_class_for(interface)
      next unless klass

      operations = JsSurface.js_operations(klass)
      record["members"].each do |member|
        next unless member["kind"] == "operation" && member["name"] && !member["static"]
        next unless operations.include?(member["name"])

        yield interface, member
      end
    end
  end

  # An interface is iterable with keys()/values()/entries()/forEach() only when
  # its IDL declares `iterable<>`; an indexed getter alone gives it @@iterator
  # and nothing more. The JS half decides this from two hand-written sets.
  def iteration_gaps
    array_like = js_name_set("ARRAY_LIKE_COLLECTIONS")
    pair_iterable = js_name_set("PAIR_ITERABLE_COLLECTIONS")
    gaps = {}
    array_like.each do |interface|
      record = data["interfaces"][interface]
      next unless record # not in the specs Dommy models (RadioNodeList inherits)

      iterable = record["members"].any? { |m| m["kind"] == "iterable" }
      listed = pair_iterable.include?(interface)
      next if iterable == listed

      gaps[interface] = iterable ? "declares iterable<> but is not given the pair methods" : "has no iterable<> but is given the pair methods"
    end
    gaps.sort.to_h
  end

  # --- webidl_tables.js [Constant] tables ----------------------------------
  # The tables live in the JS half's spec-surface file (the host runtime places
  # them on the interface object and its prototype). Reading them back is a
  # small anchored
  # parse; `constant_tables_parsed?` lets the suite fail loudly if the shape
  # this depends on is ever refactored away, rather than silently passing.

  def js_constant_tables
    @js_constant_tables ||= begin
      source = File.read(WEBIDL_TABLES_PATH)
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
      "missing_members" => member_gaps.sort.to_h,
      "reflect_gaps" => reflect_gaps,
      "void_gaps" => void_gaps,
      "arity_gaps" => arity_gaps,
      "iteration_gaps" => iteration_gaps
    }
  end

  # `RECORD_WEBIDL_GAPS=1 bundle exec rake test` rewrites the inventory after an
  # intentional change (or after regenerating interfaces.json from a newer WPT).
  def record_gaps!
    payload = {
      "README" => "Inventory of WebIDL members Dommy does not implement, and of the " \
                  "reflected attributes it implements with the wrong algorithm, recorded " \
                  "so test/test_webidl_conformance.rb can ratchet. Regenerate with " \
                  "RECORD_WEBIDL_GAPS=1 bundle exec rake test.",
      "wpt_commit" => data["wpt_commit"]
    }.merge(current_gaps)
    File.write(GAPS_PATH, JSON.pretty_generate(payload) + "\n")
  end
end
