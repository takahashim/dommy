#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate lib/dommy/js/webidl_signatures.js — the string conversions WebIDL
# makes of a script's values before an operation, constructor or attribute
# setter sees them — from test/fixtures/webidl/interfaces.json, the specs' own
# IDL as script/build_webidl_fixture.js distills it.
#
#   ruby script/build_webidl_signatures.rb          # write the file
#   ruby script/build_webidl_signatures.rb --check  # exit 1 if it is stale
#
# The bridge (host_runtime.js) converts by this table JS-side, before a value
# crosses into Ruby: it is the only place a JS object's own toString can run, a
# Symbol can throw, and null can still be told from undefined.
#
# Only string types are recorded. An argument or attribute of another type is
# null here and crosses as it is; what the conversions MEAN lives in the bridge.

require "json"

module WebIdlSignatures
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "test/fixtures/webidl/interfaces.json")
  OUTPUT = File.join(ROOT, "lib/dommy/js/webidl_signatures.js")

  STRING_TYPES = %w[DOMString USVString ByteString].freeze

  module_function

  # The string type a value of IDL type `type` is converted to, as a token the
  # bridge reads ("USVString", "DOMString?", "[LegacyNullToEmptyString]
  # DOMString"), or nil when the type is not a string type. A union of one
  # string type with Trusted Types members is that string type: Dommy has no
  # TrustedHTML / TrustedScript / TrustedScriptURL objects, so a value can only
  # ever be converted as the string member.
  def string_token(type, null_to_empty)
    return nil if type.nil?

    type = resolve(type)
    nullable = type.end_with?("?")
    base = nullable ? type.delete_suffix("?") : type
    if base.start_with?("(") && base.end_with?(")")
      members = base[1...-1].split(" or ").map { |m| resolve(m) }
      strings = members.select { |m| STRING_TYPES.include?(m) }
      return nil unless strings.size == 1 && (members - strings).all? { |m| m.start_with?("Trusted") }

      base = strings.first
    end
    return nil unless STRING_TYPES.include?(base)

    token = nullable ? "#{base}?" : base
    null_to_empty ? "[LegacyNullToEmptyString] #{token}" : token
  end

  # A typedef's name stands for the type it names (`CSSOMString` is
  # DOMString), keeping the "?" written on the name itself.
  def resolve(type)
    nullable = type.end_with?("?")
    name = nullable ? type.delete_suffix("?") : type
    seen = []
    while (named = @typedefs[name]) && !seen.include?(name)
      seen << name
      name = named
    end
    nullable && !name.end_with?("?") ? "#{name}?" : name
  end

  # One argument's conversion: its string token, with "optional " in front (an
  # undefined value is then left for the operation's default) or "..." after
  # (it applies to every remaining value).
  def argument_token(arg)
    token = string_token(arg["type"], arg["null_to_empty_string"])
    return nil unless token

    token = "optional #{token}" if arg["optional"]
    token = "#{token}..." if arg["variadic"]
    token
  end

  # The per-position conversions of a member declared with `signatures` (one
  # per overload). WebIDL picks an overload by the number of arguments and then
  # by their types; a position is converted here only where every overload that
  # has it converts it the same way, so no choice of overload is made for the
  # operation. A position some overload lacks is optional.
  def merged_arguments(signatures)
    width = signatures.map(&:size).max || 0
    (0...width).map do |i|
      present = signatures.map { |sig| sig[i] || (sig.last if sig.last && sig.last["variadic"]) }
      tokens = present.compact.map { |arg| argument_token(arg) }
      next nil if tokens.empty? || tokens.include?(nil)

      bare = tokens.map { |t| t.delete_prefix("optional ") }
      next nil unless bare.uniq.size == 1

      optional = present.include?(nil) || tokens.any? { |t| t.start_with?("optional ") }
      optional ? "optional #{bare.first}" : bare.first
    end
  end

  # WebIDL's overload resolution throws a TypeError when fewer arguments are
  # passed than the shortest overload requires: the arguments before the first
  # optional or variadic one.
  def required_count(signatures)
    signatures.map { |sig| sig.take_while { |arg| !arg["optional"] && !arg["variadic"] }.size }.min || 0
  end

  # What a call is checked and converted by: its required argument count and
  # its per-position string conversions; nil when there is neither.
  def call_entry(signatures)
    required = required_count(signatures)
    args = trim(merged_arguments(signatures))
    return nil if required.zero? && args.empty?

    entry = {"required" => required}
    entry["arguments"] = args unless args.empty?
    entry
  end

  def interface_entry(record)
    entry = {}
    operations = {}
    statics = {}
    attributes = {}
    record["members"].each do |member|
      case member["kind"]
      when "operation"
        next unless member["name"] && member["signatures"]

        call = call_entry(member["signatures"])
        (member["static"] ? statics : operations)[member["name"]] = call if call
      when "constructor"
        call = call_entry(member["signatures"])
        entry["constructor"] = call if call
      when "attribute"
        next if member["readonly"] || member["static"]

        token = string_token(member["type"], member["null_to_empty_string"])
        attributes[member["name"]] = token if token
      end
    end
    entry["inherits"] = record["inherits"] if record["inherits"]
    entry["operations"] = operations.sort.to_h unless operations.empty?
    entry["static_operations"] = statics.sort.to_h unless statics.empty?
    entry["attributes"] = attributes.sort.to_h unless attributes.empty?
    entry
  end

  # Positions after the last converted one carry no conversion: drop them.
  def trim(args)
    args = args.dup
    args.pop while !args.empty? && args.last.nil?
    args
  end

  def table
    data = JSON.parse(File.read(FIXTURE))
    @typedefs = data.fetch("typedefs", {})
    interfaces = data["interfaces"]
    entries = interfaces.to_h { |name, record| [name, interface_entry(record)] }
    interfaces.each { |name, record| shadow(name, record, interfaces, entries) }
    out = {}
    entries.sort.each do |name, entry|
      # An interface with nothing to convert still names its parent, so a
      # lookup can walk through it to an ancestor that does.
      out[name] = entry unless entry.empty?
    end
    [data["wpt_commit"], out]
  end

  BUCKETS = {"operation" => "operations", "attribute" => "attributes"}.freeze

  # A lookup takes the nearest declaration, so a member an interface declares
  # with no string conversion must still stop the walk before an ancestor's
  # declaration of the same name that has one: it is recorded as null.
  def shadow(name, record, interfaces, entries)
    record["members"].each do |member|
      bucket = BUCKETS[member["kind"]]
      next unless bucket && member["name"] && !member["static"]
      next if entries[name].dig(bucket, member["name"])

      ancestor = interfaces.dig(name, "inherits")
      while ancestor
        if entries.dig(ancestor, bucket, member["name"])
          (entries[name][bucket] ||= {})[member["name"]] = nil
          entries[name][bucket] = entries[name][bucket].sort.to_h
          break
        end
        ancestor = interfaces.dig(ancestor, "inherits")
      end
    end
  end

  def render
    commit, entries = table
    body = format_value(entries, 0)
    <<~JS
      // GENERATED by script/build_webidl_signatures.rb from
      // test/fixtures/webidl/interfaces.json (web-platform-tests #{commit}).
      // Do not edit by hand: re-run the script (`rake webidl:signatures`).
      //
      // For each interface, what WebIDL checks and converts of a script's
      // values before the member sees them. An operation, static operation or
      // constructor has `required`, the number of arguments a call must pass
      // (fewer is a TypeError), and `arguments`, one string conversion per
      // position; a writable attribute has its value's string conversion. A
      // conversion is a string type ("DOMString", "USVString", "ByteString"),
      // "?" after it when nullable, "[LegacyNullToEmptyString] " before it when
      // null means "", "optional " before it when undefined is left for the
      // default, and "..." after it when it converts every remaining argument.
      // null is a position that is not a string type, or a member with nothing
      // to check where an ancestor's member of the same name has something.
      // `inherits` is the IDL parent.
      //
      // Read by host_runtime.js (see "WebIDL string conversions" there), which
      // is the one place the conversions are carried out.
      globalThis.__rbIdlSignatures = #{body};
    JS
  end

  # JSON, one interface member per line: a member's entry is short enough to
  # read whole, and a line per member keeps a regenerated diff to the members
  # whose IDL changed.
  def format_value(value, depth)
    return JSON.generate(value) unless value.is_a?(Hash) && !value.key?("required")

    pad = "  " * depth
    lines = value.map { |k, v| "#{pad}  #{JSON.generate(k)}: #{format_value(v, depth + 1)}" }
    "{\n#{lines.join(",\n")}\n#{pad}}"
  end

  def run(argv)
    content = render
    if argv.include?("--check")
      current = File.exist?(OUTPUT) ? File.read(OUTPUT) : ""
      return 0 if current == content

      warn "#{OUTPUT} is stale: re-run ruby script/build_webidl_signatures.rb"
      return 1
    end
    File.write(OUTPUT, content)
    puts "wrote #{OUTPUT}: #{table.last.size} interfaces"
    0
  end
end

exit WebIdlSignatures.run(ARGV) if $PROGRAM_NAME == __FILE__
