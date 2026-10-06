#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate lib/dommy/js/webidl_members.js — which IDL attributes and
# operations go on each interface prototype object — from the specs' own IDL
# (test/fixtures/webidl/interfaces.json) intersected with what Dommy's bridge
# classes answer.
#
#   ruby script/build_webidl_members.rb          # write the file
#   ruby script/build_webidl_members.rb --check  # exit 1 if it is stale
#
# WebIDL puts every regular attribute (as an accessor) and operation of an
# interface on its interface prototype object, which is where feature
# detection looks: `"popover" in HTMLElement.prototype`,
# `Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")`. An
# instance's value still comes through the bridge's proxy; the prototype
# member is what makes it visible there, and what `Interface.prototype.x.call`
# runs.
#
# Only members Dommy answers are listed — a prototype member for something the
# host cannot answer would turn today's `undefined` into a wrong value. "Answers"
# is the WebIDL audit's own reading of the bridge classes (test/support/
# webidl_audit.rb, through JsSurface), so this needs MRI and loads the library.
# Adding a member to a bridge class therefore makes this file stale, which the
# audit test reports.

require "json"

module WebIdlMembers
  ROOT = File.expand_path("..", __dir__)
  OUTPUT = File.join(ROOT, "lib/dommy/js/webidl_members.js")

  # Interfaces whose prototype members are installed by hand-written JS rather
  # than through the host: `new Event()` / `new CustomEvent()` build pure-JS
  # objects whose members are host_runtime.js's own JS_EVENT_MEMBERS.
  JS_IMPLEMENTED = %w[Event CustomEvent].freeze

  module_function

  def load_library
    $LOAD_PATH.unshift(File.join(ROOT, "lib"))
    require "dommy"
    require File.join(ROOT, "test/support/webidl_audit")
    # Loading a Window pulls in every bridge class, so the class index sees the
    # whole surface rather than whatever happened to be autoloaded.
    Dommy::Window.new
  end

  # { "Interface" => { "m" => [...], "g" => [...], "p" => [...] } }: operations,
  # readonly attributes (a getter), and writable ones (getter and setter). A
  # [PutForwards] attribute has a setter (it forwards the assignment), and so
  # does a [Replaceable] one (an assignment replaces it). [LegacyUnforgeable]
  # members live on each instance, not the prototype, and static ones on the
  # interface object; neither is listed.
  def table
    WebIdlAudit.window_interfaces.sort.each_with_object({}) do |(name, record), out|
      next if JS_IMPLEMENTED.include?(name)

      klass = WebIdlAudit.ruby_class_for(name)
      next unless klass

      properties = JsSurface.js_properties(klass)
      operations = JsSurface.js_operations(klass)
      entry = {"m" => [], "g" => [], "p" => []}
      record["members"].each do |member|
        next if member["static"] || member["unforgeable"]

        case member["kind"]
        when "operation"
          entry["m"] << member["name"] if member["name"] && operations.include?(member["name"])
        when "attribute"
          next unless properties.include?(member["name"])

          settable = !member["readonly"] || member["put_forwards"] || member["replaceable"]
          entry[settable ? "p" : "g"] << member["name"]
        end
      end
      # A stringifier (`stringifier;` or `stringifier attribute`) is toString.
      stringifier = record["members"].any? { |m| m["special"] == "stringifier" || m["stringifier"] }
      entry["m"] << "toString" if stringifier && operations.include?("toString")
      entry.transform_values! { |names| names.uniq.sort }
      entry.reject! { |_, names| names.empty? }
      out[name] = entry unless entry.empty?
    end
  end

  # { "Interface" => { "enumerable" => …, "writable" => …, "overrideBuiltins" => … } }
  # for each interface with a named property getter (its own or inherited) whose
  # bridge class supports named properties (`__js_named_props__`): the WebIDL
  # legacy-platform-object behaviour the proxy gives them. Enumerable unless
  # [LegacyUnenumerableNamedProperties] is on it or an ancestor; writable when
  # the chain has a named setter; [LegacyOverrideBuiltIns] likewise inherited.
  def named_properties
    WebIdlAudit.data["interfaces"].sort.each_with_object({}) do |(name, _record), out|
      klass = WebIdlAudit.ruby_class_for(name)
      next unless klass && klass.method_defined?(:__js_named_props__)
      next unless WebIdlAudit.named_getter_source(name)

      out[name] = {
        "enumerable" => !WebIdlAudit.inherited_flag?(name, "unenumerable_named_properties"),
        "writable" => named_setter?(name),
        "overrideBuiltins" => WebIdlAudit.inherited_flag?(name, "override_builtins")
      }
    end
  end

  def named_setter?(interface)
    while interface
      record = WebIdlAudit.data["interfaces"][interface]
      return false unless record
      return true if record["members"].any? { |m| m["special"] == "setter" && m["indexed"] == false }

      interface = record["inherits"]
    end
    false
  end

  def render
    commit = WebIdlAudit.data["wpt_commit"]
    lines = table.map do |name, entry|
      "  #{JSON.generate(name)}: {#{entry.map { |k, v| "#{JSON.generate(k)}: #{JSON.generate(v)}" }.join(", ")}}"
    end
    named = named_properties.map do |name, flags|
      "  #{JSON.generate(name)}: {#{flags.map { |k, v| "#{k}: #{v}" }.join(", ")}}"
    end
    <<~JS
      // GENERATED by script/build_webidl_members.rb from
      // test/fixtures/webidl/interfaces.json (web-platform-tests #{commit}) and the
      // members Dommy's bridge classes answer. Do not edit by hand: re-run the
      // script (`rake webidl:members`) after adding or removing a member.
      //
      // The members WebIDL puts on each interface prototype object: `m`
      // operations, `g` readonly attributes (a getter), `p` attributes with a
      // setter (writable, [PutForwards] or [Replaceable]). host_runtime.js
      // seeds them (seedInterfaceMembers), alongside webidl_tables.js's
      // hand-kept INTERFACE_MEMBERS for the members no bridge class answers by
      // name.
      globalThis.__rbIdlMembers = {
      #{lines.join(",\n")}
      };

      // The legacy platform objects with named properties (a named getter, own
      // or inherited, that the bridge class supports): whether the names are
      // enumerable ([LegacyUnenumerableNamedProperties] on it or an ancestor
      // makes them not), writable (a named setter) and resolved before the
      // prototype chain ([LegacyOverrideBuiltIns]).
      globalThis.__rbIdlNamedProperties = {
      #{named.join(",\n")}
      };
    JS
  end

  def run(argv)
    load_library
    content = render
    if argv.include?("--check")
      current = File.exist?(OUTPUT) ? File.read(OUTPUT) : ""
      return 0 if current == content

      warn "#{OUTPUT} is stale: re-run ruby script/build_webidl_members.rb"
      return 1
    end
    File.write(OUTPUT, content)
    puts "wrote #{OUTPUT}: #{table.size} interfaces"
    0
  end
end

exit WebIdlMembers.run(ARGV) if $PROGRAM_NAME == __FILE__
