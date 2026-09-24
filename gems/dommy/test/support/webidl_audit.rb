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

  # The text between the braces of `const NAME = { … };`, whether the table is
  # written on one line or many.
  def js_object_body(constant)
    source = tables_source
    open_brace = source.index("const #{constant} = {")
    return "" unless open_brace

    start = source.index("{", open_brace)
    depth = 0
    index = start
    while index < source.length
      depth += 1 if source[index] == "{"
      depth -= 1 if source[index] == "}"
      break if depth.zero?

      index += 1
    end
    source[(start + 1)...index].to_s
  end

  # `{ Interface: ["a", "b"] }` tables in the JS half.
  def js_interface_name_sets(constant)
    body = js_object_body(constant)
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
    body = js_object_body(constant)
    raise "#{constant} is missing from webidl_tables.js" if body.empty?
    body.scan(/(\w+):\s*(\d+)/).to_h { |name, value| [name, value.to_i] }
  end

  def js_interface_arity
    body = js_object_body("INTERFACE_METHOD_ARITY")
    body.scan(/(\w+):\s*\{([^}]*)\}/).to_h do |interface, members|
      [interface, members.scan(/(\w+):\s*(\d+)/).to_h { |name, value| [name, value.to_i] }]
    end
  end

  # WebIDL constructor `length` = the count of required arguments, stamped onto
  # each seeded interface constructor from the JS half's CONSTRUCTOR_ARITY. An
  # interface the IDL gives no constructor — or one whose arguments are all
  # optional — keeps the default 0, so a name only appears in the table when its
  # required count is nonzero. Only seeded interfaces are judged; one Dommy does
  # not expose at all is a missing interface, recorded elsewhere.
  def constructor_arity_gaps
    declared = js_table("CONSTRUCTOR_ARITY")
    gaps = {}
    data["interfaces"].each do |interface, record|
      next unless seeded_interfaces.include?(interface)

      ctor = record["members"].find { |m| m["kind"] == "constructor" }
      expected = ctor ? ctor["required"] : 0
      got = declared.fetch(interface, 0)
      next if got == expected

      gaps[interface] = "length #{got} (IDL requires #{expected})"
    end
    gaps.sort.to_h
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

  # --- WebIDL's legacy extended attributes ----------------------------------
  # [LegacyNullToEmptyString], [LegacyUnforgeable], [Unscopable] and the two
  # that shape a legacy platform object's named properties are all written in the
  # IDL, and all answered in the JS half by a hand-written table.

  # Attributes whose setter turns null into "" — declared per attribute in the
  # IDL, answered by a table keyed on the property NAME alone, so a name that is
  # null-to-empty on one interface and a plain DOMString on another (`value` is,
  # on input and textarea versus option and button) cannot be right for both.
  def null_to_empty_gaps
    listed = js_name_set("NULL_TO_EMPTY_STRING_SETTERS")
    per_interface = js_interface_name_sets("INTERFACE_NULL_TO_EMPTY_STRING_SETTERS")
    gaps = {}
    each_implemented_attribute do |interface, member|
      name = member["name"]
      declared = listed.include?(name) || (per_interface[interface] || Set.new).include?(name)
      next if !!member["null_to_empty_string"] == declared

      gaps["#{interface}.#{name}"] =
        member["null_to_empty_string"] ? "null must become \"\", and does not" : "is not [LegacyNullToEmptyString]"
    end
    gaps.sort.to_h
  end

  # [LegacyUnforgeable] members are own, non-configurable properties of each
  # instance rather than of the prototype — which is the whole of what stops a
  # page replacing `location.href`.
  def unforgeable_gaps
    attrs = js_unforgeable_attrs
    methods = js_interface_name_sets("UNFORGEABLE_METHODS")
    gaps = {}
    data["interfaces"].each do |interface, record|
      next unless ruby_class_for(interface)

      record["members"].each do |member|
        next unless member["name"] && (member["kind"] == "attribute" || member["kind"] == "operation")

        declared = member["kind"] == "attribute" ? (attrs[interface] || {}).key?(member["name"]) : (methods[interface] || Set.new).include?(member["name"])
        next if !!member["unforgeable"] == declared

        gaps["#{interface}.#{member['name']}"] =
          member["unforgeable"] ? "is [LegacyUnforgeable] but sits on the prototype" : "is pinned to the instance but is not [LegacyUnforgeable]"
      end
    end
    gaps.sort.to_h
  end

  # `{ Interface: { name: RO|RW } }`.
  def js_unforgeable_attrs
    body = js_object_body("UNFORGEABLE_ATTRS")
    body.scan(/(\w+):\s*\{(.*?)\n?\s*\},?\n/m).to_h do |interface, members|
      [interface, members.scan(/(\w+):\s*(RO|RW)/).to_h { |name, mode| [name, mode == "RW"] }]
    end
  end

  # [Unscopable] members must not bind inside `with (element) { … }`.
  def unscopable_gaps
    declared = js_interface_name_sets("INTERFACE_UNSCOPABLES")
    gaps = {}
    data["interfaces"].each do |interface, record|
      next unless ruby_class_for(interface)

      record["members"].each do |member|
        next unless member["name"]
        next if !!member["unscopable"] == (declared[interface] || Set.new).include?(member["name"])

        gaps["#{interface}.#{member['name']}"] =
          member["unscopable"] ? "is [Unscopable] and is not declared" : "is declared unscopable but the IDL does not say so"
      end
    end
    gaps.sort.to_h
  end

  # A legacy platform object's named properties: whether it has a named getter
  # at all, whether those names enumerate, and whether they resolve before the
  # prototype chain ([LegacyOverrideBuiltIns]).
  def named_property_gaps
    declared = js_named_prop_collections
    gaps = {}
    data["interfaces"].each do |interface, record|
      next unless ruby_class_for(interface)

      source = named_getter_source(interface)
      entry = declared[interface]
      if source.nil? != entry.nil?
        gaps[interface] = source ? "has a named getter and is not declared" : "is declared with named properties the IDL does not give it"
        next
      end
      next unless entry

      enumerable = !inherited_flag?(interface, "unenumerable_named_properties")
      override = inherited_flag?(interface, "override_builtins")
      notes = []
      notes << "enumerable should be #{enumerable}" if entry[:enumerable] != enumerable
      notes << "overrideBuiltins should be #{override}" if entry[:override] != override
      gaps[interface] = notes.join(", ") unless notes.empty?
    end
    gaps.sort.to_h
  end

  # The record of the interface that declares the NAMED property getter this one
  # answers with — itself, or the nearest ancestor that has one. Nil when nothing
  # in the chain does.
  def named_getter_source(interface)
    while interface
      record = data["interfaces"][interface]
      return nil unless record
      return record if record["members"].any? { |m| m["special"] == "getter" && m["indexed"] == false }

      interface = record["inherits"]
    end
    nil
  end

  # [LegacyUnenumerableNamedProperties] and [LegacyOverrideBuiltIns] apply to the
  # interface that carries them AND to everything inheriting from it, so an
  # HTMLFormControlsCollection's names are as unenumerable as an
  # HTMLCollection's however it redeclares the getter.
  def inherited_flag?(interface, flag)
    while interface
      record = data["interfaces"][interface]
      return false unless record
      return true if record[flag]

      interface = record["inherits"]
    end
    false
  end

  def js_named_prop_collections
    body = tables_source[/const NAMED_PROP_COLLECTIONS = new Map\(\[(.*?)\n  \]\);/m, 1].to_s
    body.scan(/\["(\w+)",\s*\{([^}]*)\}\]/).to_h do |interface, flags|
      [interface, {enumerable: flags.include?("enumerable: true"), override: flags.include?("overrideBuiltins: true")}]
    end
  end

  # Every attribute an interface declares that Dommy answers.
  def each_implemented_attribute
    data["interfaces"].each do |interface, record|
      klass = ruby_class_for(interface)
      next unless klass

      properties = JsSurface.js_properties(klass) | (klass.respond_to?(:reflected_property_map) ? klass.reflected_property_map.keys : [])
      record["members"].each do |member|
        next unless member["kind"] == "attribute" && !member["static"]
        next unless properties.include?(member["name"])

        yield interface, member
      end
    end
  end

  # --- [SameObject] identity ------------------------------------------------
  # An attribute the IDL marks [SameObject] must answer with the SAME object on
  # every read (`el.attributes === el.attributes`). The bridge keys handles by
  # object_id, so a JS proxy has a stable identity exactly when its Ruby object
  # does; Ruby object identity is therefore what to check. A sample instance is
  # built for each interface where one is cheap (below); an interface with no
  # sample — ElementInternals, MimeTypeArray, an AudioTrackList — is left to the
  # member inventory rather than guessed at. An attribute Dommy does not answer
  # returns the same ABSENT sentinel twice, so a missing member is not a
  # same-object gap.
  def same_object_gaps
    samples = same_object_samples
    gaps = {}
    data["interfaces"].each do |interface, record|
      object = samples[interface]
      next unless object

      record["members"].each do |member|
        next unless member["kind"] == "attribute" && member["same_object"]

        first = object.__js_get__(member["name"])
        second = object.__js_get__(member["name"])
        next if first.equal?(second)

        gaps["#{interface}.#{member['name']}"] = "answers a new object on every read"
      end
    end
    gaps.sort.to_h
  end

  # [PutForwards]: `obj.attr = v` means `obj.attr.<target> = v` — assigning to a
  # DOMTokenList-reflecting attribute rewrites the attribute's tokens, to a
  # style attribute rewrites the declaration block, and so on. Dommy answers the
  # write from several shapes, so the check is dynamic: write a probe value to
  # the attribute, then read the forwarded member back and see it took. An
  # attribute Dommy does not answer (the ABSENT sentinel, nil, or a primitive in
  # its place) is a missing member, recorded elsewhere, and is skipped here; an
  # attribute it answers but whose write returns Bridge::UNHANDLED is a real
  # forwarding gap, since [PutForwards] is exactly what makes it writable.
  PUT_FORWARDS_PROBES = {
    "value" => ["aa bb", ->(after) { after == "aa bb" }],
    "cssText" => ["background: blue", ->(after) { after.to_s.include?("background") }],
    "href" => ["https://example.com/next", ->(after) { after == "https://example.com/next" }],
    "mediaText" => ["(min-width: 2px)", ->(after) { after.to_s.include?("min-width") }]
  }.freeze

  def put_forwards_gaps
    samples = same_object_samples
    gaps = {}
    data["interfaces"].each do |interface, record|
      object = samples[interface]
      next unless object

      record["members"].each do |member|
        next unless member["kind"] == "attribute" && member["put_forwards"]

        name = member["name"]
        target = member["put_forwards"]
        probe = PUT_FORWARDS_PROBES[target]
        next unless probe

        inner = object.__js_get__(name)
        next unless inner.respond_to?(:__js_get__) # ABSENT / nil / a primitive: not implemented

        result = object.__js_set__(name, probe.first)
        after = object.__js_get__(name).__js_get__(target)
        next if probe.last.call(after)

        gaps["#{interface}.#{name}"] =
          result.equal?(Dommy::Bridge::UNHANDLED) ? "accepts no write (should forward to #{target})" : "does not forward to #{target}"
      end
    end
    gaps.sort.to_h
  end

  # Sample instances for the [SameObject] check, keyed by interface name. One
  # throwaway Window with a document exercising the collections; the CSS rule
  # interfaces are the rules of its one stylesheet.
  SAME_OBJECT_ELEMENTS = {
    "HTMLAnchorElement" => "a",
    "HTMLAreaElement" => "area",
    "HTMLDataListElement" => "datalist",
    "HTMLFieldSetElement" => "fieldset",
    "HTMLFormElement" => "form",
    "HTMLIFrameElement" => "iframe",
    "HTMLLinkElement" => "link",
    "HTMLMapElement" => "map",
    "HTMLOutputElement" => "output",
    "HTMLScriptElement" => "script",
    "HTMLSelectElement" => "select",
    "HTMLStyleElement" => "style",
    "HTMLTableElement" => "table",
    "HTMLTableRowElement" => "tr",
    "HTMLTableSectionElement" => "tbody"
  }.freeze

  def same_object_samples
    @same_object_samples ||= build_same_object_samples
  end

  def build_same_object_samples
    window = Dommy::Window.new
    document = window.document
    document.head.inner_html = <<~HTML
      <link rel="stylesheet" href="a.css">
      <style>@import url("x.css"); .a { color: red } @media (min-width: 1px) { .b { color: blue } }</style>
      <script></script>
    HTML
    document.body.inner_html = <<~HTML
      <form id="f" name="f1"><input name="a"><select id="s"><option>x</option></select></form>
      <a id="a" href="x" rel="nofollow">l</a>
      <table id="t"><tbody><tr><td>c</td></tr></tbody></table>
      <iframe id="if"></iframe><output id="o"></output><datalist id="dl"></datalist>
      <fieldset id="fs"></fieldset><map id="m"><area></map>
      <div id="dv" class="c" data-x="1"></div>
    HTML
    element = document.get_element_by_id("dv")
    sheet = document.query_selector("style")&.sheet
    rules = sheet ? sheet.css_rules.to_a : []
    samples = {
      "AbortController" => Dommy::AbortController.new,
      "DataTransfer" => Dommy::DataTransfer.new,
      "Document" => document,
      "DocumentFragment" => document.create_document_fragment,
      "Element" => element,
      "Node" => element,
      "HTMLElement" => element,
      "Window" => window,
      "Navigator" => window.navigator,
      "NodeIterator" => document.create_node_iterator(element),
      "TreeWalker" => document.create_tree_walker(element),
      "ShadowRoot" => element.attach_shadow({"mode" => "open"}),
      "URL" => Dommy::URL.new("https://example.com/?a=1"),
      "Request" => Dommy::Request.new("https://example.com/", nil, window),
      "Response" => Dommy::Response.__construct__(window, nil, nil),
      "XMLHttpRequest" => Dommy::XMLHttpRequest.new(window),
      "MutationRecord" => Dommy::MutationRecord.new(type: "childList", target: element),
      "CSSStyleSheet" => sheet,
      "StyleSheet" => sheet,
      "CSSImportRule" => rules.find { |r| r.type == 3 },
      "CSSStyleRule" => rules.find { |r| r.type == 1 },
      "CSSMediaRule" => rules.find { |r| r.type == 4 },
      "CSSGroupingRule" => rules.find { |r| r.type == 4 },
      "CSSPageRule" => rules.find { |r| r.type == 6 }
    }
    SAME_OBJECT_ELEMENTS.each do |interface, selector|
      samples[interface] = document.query_selector(selector)
    end
    samples
  end

  # --- what sits on which prototype -----------------------------------------
  #
  # Whether a page may ASSIGN to an attribute is not audited directly: Dommy
  # answers a write from several shapes — a `when` arm, a guard clause, a
  # reflect_* declaration, a module — and reading them statically finds only
  # some, which makes a ratchet that cries wolf. Where readonly IS observable is
  # the seeded prototype descriptor, which is what a page reflects on, and that
  # is what this checks.

  # INTERFACE_MEMBERS is what the JS half puts on each interface PROTOTYPE, so a
  # page's `'appendChild' in Node.prototype` and `Element.prototype.remove.call`
  # resolve. Each name has to be a member the IDL gives that interface — not an
  # invention, not one that belongs to an ancestor — and the table's split
  # between `g` (readonly attributes) and `p` (read-write ones) has to match.
  def seeded_member_gaps
    gaps = {}
    js_interface_members.each do |interface, groups|
      # An interface the fixture only sees a PARTIAL of (MouseEvent, whose base is
      # in a spec outside the audited set) cannot be judged from here.
      record = data["interfaces"][interface]
      next unless record

      operations = record["members"].select { |m| m["kind"] == "operation" }.map { |m| m["name"] }.compact.to_set
      # A stringifier is an unnamed special operation, and what it gives the
      # interface is `toString`.
      operations << "toString" if record["members"].any? { |m| m["special"] == "stringifier" || (m["kind"] == "special" && m["special"] == "stringifier") }
      attributes = record["members"].select { |m| m["kind"] == "attribute" }.to_h { |m| [m["name"], m] }
      groups[:m].each do |name|
        gaps["#{interface}.#{name}"] = "seeded as an operation the interface does not declare" unless operations.include?(name)
      end
      (groups[:g] + groups[:p]).each do |name|
        next gaps["#{interface}.#{name}"] = "seeded as an attribute the interface does not declare" unless attributes[name]

        readonly = attributes[name]["readonly"] && attributes[name]["put_forwards"].nil?
        seeded_readonly = groups[:g].include?(name)
        next if readonly == seeded_readonly

        gaps["#{interface}.#{name}"] = readonly ? "seeded with a setter the IDL does not give it" : "seeded without the setter the IDL gives it"
      end
    end
    gaps.sort.to_h
  end

  # `{ Interface: { m: [...], g: [...], p: [...] } }` out of the JS half.
  def js_interface_members
    body = js_object_body("INTERFACE_MEMBERS")
    entries = {}
    body.scan(/(\w+):\s*\{/) do
      interface = ::Regexp.last_match(1)
      entries[interface] = js_member_groups(body, ::Regexp.last_match.end(0))
    end
    entries
  end

  def js_member_groups(body, from)
    depth = 1
    index = from
    while index < body.length && depth.positive?
      depth += 1 if body[index] == "{"
      depth -= 1 if body[index] == "}"
      index += 1
    end
    chunk = body[from...(index - 1)].to_s
    %i[m g p].to_h do |group|
      list = chunk[/\b#{group}:\s*\[(.*?)\]/m, 1].to_s
      [group, list.scan(/"([^"]+)"/).flatten]
    end
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
      "constructor_arity_gaps" => constructor_arity_gaps,
      "iteration_gaps" => iteration_gaps,
      "null_to_empty_gaps" => null_to_empty_gaps,
      "unforgeable_gaps" => unforgeable_gaps,
      "unscopable_gaps" => unscopable_gaps,
      "named_property_gaps" => named_property_gaps,
      "same_object_gaps" => same_object_gaps,
      "put_forwards_gaps" => put_forwards_gaps,
      "seeded_member_gaps" => seeded_member_gaps
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
