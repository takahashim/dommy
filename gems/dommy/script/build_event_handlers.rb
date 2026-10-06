#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate the event handler tables — which event handler IDL attributes each
# interface declares, and which of them HTML elements accept as content
# attributes — from test/fixtures/webidl/interfaces.json, the specs' own IDL as
# script/build_webidl_fixture.js distills it. One run writes both halves:
#
#   lib/dommy/js/webidl_event_handlers.js        the bridge's chain lookup
#   lib/dommy/internal/event_handler_tables.rb   the host's (the fixture is a
#                                                test file, not shipped in the gem)
#
#   ruby script/build_event_handlers.rb          # write both files
#   ruby script/build_event_handlers.rb --check  # exit 1 if either is stale
#
# HTML §8.1.8.1: an event handler IDL attribute is an attribute whose type is
# EventHandler, OnErrorEventHandler or OnBeforeUnloadEventHandler. Which
# objects have one is the IDL's business — `onclick` is on HTMLElement,
# Document and Window through GlobalEventHandlers, `onreadystatechange` on
# Document alone, `onfullscreenchange` on Element and Document — so a name is an
# event handler only on an object whose interface chain declares it:
# `div.onbogus = f` is an ordinary expando, and `onClick` names nothing.
#
# §8.1.8.2 then says which of them are also CONTENT attributes: the
# GlobalEventHandlers ones on every HTML element (the specs that extend the
# mixin — Pointer Events, Touch Events, CSS Animations / Transitions — add
# theirs to it), and on body and frameset the WindowEventHandlers ones too.
# What the IDL cannot say is written below as overlays, each citing its spec.

require "json"
require "set"

module EventHandlerTables
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "test/fixtures/webidl/interfaces.json")
  JS_OUTPUT = File.join(ROOT, "lib/dommy/js/webidl_event_handlers.js")
  RUBY_OUTPUT = File.join(ROOT, "lib/dommy/internal/event_handler_tables.rb")

  # HTML §8.1.8.1 "event handler IDL attributes": the three callback types.
  HANDLER_TYPES = %w[EventHandler OnErrorEventHandler OnBeforeUnloadEventHandler].freeze

  # HTML §8.1.8.2: "The following are the event handlers (and their
  # corresponding event handler event types) supported by body and frameset
  # elements that are exposed on the Window object" — the
  # WindowEventHandlers, and this list, which the spec gives in prose as "the
  # Window-reflecting body element event handler set". On body/frameset these
  # are the Window's handlers.
  WINDOW_REFLECTING_BODY_ELEMENT_SET = %w[onblur onerror onfocus onload onresize onscroll].freeze

  # HTML §8.1.8.2's tables give each handler its "event handler event type",
  # which is the name without "on" except for the four legacy WebKit-prefixed
  # handlers, whose event types are camel-cased.
  EVENT_TYPE_OVERRIDES = {
    "onwebkitanimationend" => "webkitAnimationEnd",
    "onwebkitanimationiteration" => "webkitAnimationIteration",
    "onwebkitanimationstart" => "webkitAnimationStart",
    "onwebkittransitionend" => "webkitTransitionEnd"
  }.freeze

  # Interfaces outside the fixture's specs whose IDL includes a handler mixin
  # the fixture does have: SVG 2 (`SVGElement includes GlobalEventHandlers;`)
  # and MathML Core (`MathMLElement includes GlobalEventHandlers;`). Their
  # specs bring in large surfaces Dommy does not audit, so the one line each
  # that matters here is restated rather than the whole IDL folded in.
  MIXIN_INCLUDES_OUTSIDE_FIXTURE = {
    "SVGElement" => "GlobalEventHandlers",
    "MathMLElement" => "GlobalEventHandlers"
  }.freeze

  module_function

  def data
    @data ||= JSON.parse(File.read(FIXTURE, encoding: "UTF-8"))
  end

  def handler?(member)
    member["kind"] == "attribute" && !member["static"] && HANDLER_TYPES.include?(member["type"])
  end

  # The handler names a mixin declares, read off any interface that includes it
  # (the fixture folds mixin members into their includers, tagged `mixin`).
  def mixin_handlers(mixin)
    data["interfaces"].each_value.flat_map do |record|
      record["members"].select { |m| handler?(m) && m["mixin"] == mixin }.map { |m| m["name"] }
    end.uniq.sort
  end

  # Interface -> the event handler IDL attributes it declares itself (its own
  # members and its mixins', not its ancestors'): the lookup walks the chain.
  def by_interface
    table = data["interfaces"].sort.each_with_object({}) do |(name, record), out|
      names = record["members"].select { |m| handler?(m) }.map { |m| m["name"] }.uniq.sort
      out[name] = names unless names.empty?
    end
    MIXIN_INCLUDES_OUTSIDE_FIXTURE.each do |interface, mixin|
      raise "#{interface} is in the fixture now; drop its overlay" if data["interfaces"].key?(interface)

      table[interface] = mixin_handlers(mixin)
    end
    table.sort.to_h
  end

  # The event handler content attributes of every HTML element (and SVG /
  # MathML element, through the overlay above).
  def global_event_handlers = mixin_handlers("GlobalEventHandlers")

  # The further content attributes of body and frameset.
  def window_event_handlers = mixin_handlers("WindowEventHandlers")

  def commit = data["wpt_commit"]

  def render_js
    lines = by_interface.map { |name, names| "  #{JSON.generate(name)}: #{JSON.generate(names)}" }
    <<~JS
      // GENERATED by script/build_event_handlers.rb from
      // test/fixtures/webidl/interfaces.json (web-platform-tests #{commit}).
      // Do not edit by hand: re-run the script (`rake webidl:event_handlers`).
      //
      // The event handler IDL attributes (HTML §8.1.8.1: attributes of type
      // EventHandler, OnErrorEventHandler or OnBeforeUnloadEventHandler) each
      // interface declares itself, its mixins' included. A name is an event
      // handler on an object when an interface in its chain declares it, which
      // is what host_runtime.js looks up (eventHandlersOf).
      globalThis.__rbIdlEventHandlers = {
      #{lines.join(",\n")}
      };
    JS
  end

  def ruby_words(names, indent)
    width = 100 - indent.length
    rows = names.each_with_object([+""]) do |name, acc|
      acc << +"" if !acc.last.empty? && acc.last.length + name.length + 1 > width
      acc.last << " " unless acc.last.empty?
      acc.last << name
    end
    "%w[\n#{rows.map { |r| "#{indent}  #{r}" }.join("\n")}\n#{indent}]"
  end

  def render_ruby
    indent = "      "
    entries = by_interface.map do |name, names|
      "#{indent}  #{JSON.generate(name)} => #{ruby_words(names, "#{indent}  ")}.freeze"
    end
    <<~RUBY
      # frozen_string_literal: true

      # GENERATED by script/build_event_handlers.rb from
      # test/fixtures/webidl/interfaces.json (web-platform-tests #{commit}).
      # Do not edit by hand: re-run the script (`rake webidl:event_handlers`).

      module Dommy
        module Internal
          # HTML §8.1.8 event handlers, as the specs' IDL declares them. See
          # Internal::EventHandlers for what reads them.
          module EventHandlerTables
            # Interface -> the event handler IDL attributes it declares itself
            # (its mixins' included, its ancestors' not).
            BY_INTERFACE = {
      #{entries.join(",\n")}
            }.freeze

            # GlobalEventHandlers: event handler content attributes of every HTML
            # element (and of SVG and MathML elements, whose IDL includes the mixin).
            GLOBAL_EVENT_HANDLERS = #{ruby_words(global_event_handlers, indent)}.to_set.freeze

            # WindowEventHandlers: further content attributes of body and frameset.
            WINDOW_EVENT_HANDLERS = #{ruby_words(window_event_handlers, indent)}.to_set.freeze

            # HTML §8.1.8.2's "Window-reflecting body element event handler set",
            # which the spec lists in prose: on body/frameset, these and the
            # WindowEventHandlers are the Window's handlers.
            WINDOW_REFLECTING_BODY_ELEMENT_SET = #{ruby_words(WINDOW_REFLECTING_BODY_ELEMENT_SET, indent)}.to_set.freeze

            # The handlers whose event handler event type (§8.1.8.2's tables) is
            # not simply the name without "on".
            EVENT_TYPE_OVERRIDES = {
      #{EVENT_TYPE_OVERRIDES.map { |k, v| "#{indent}  #{JSON.generate(k)} => #{JSON.generate(v)}" }.join(",\n")}
            }.freeze
          end
        end
      end
    RUBY
  end

  def outputs
    {JS_OUTPUT => render_js, RUBY_OUTPUT => render_ruby}
  end

  def run(argv)
    if argv.include?("--check")
      stale = outputs.reject { |path, content| File.exist?(path) && File.read(path, encoding: "UTF-8") == content }.keys
      return 0 if stale.empty?

      stale.each { |path| warn "#{path} is stale: re-run ruby script/build_event_handlers.rb" }
      return 1
    end
    outputs.each { |path, content| File.write(path, content, encoding: "UTF-8") }
    puts "wrote #{JS_OUTPUT} and #{RUBY_OUTPUT}: #{by_interface.size} interfaces"
    0
  end
end

exit EventHandlerTables.run(ARGV) if $PROGRAM_NAME == __FILE__
