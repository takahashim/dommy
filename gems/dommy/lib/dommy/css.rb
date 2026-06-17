# frozen_string_literal: true

require_relative "internal/css/supports"

module Dommy
  # `CSSStyleSheet` — the sheet itself doesn't interpret rule text; it
  # acts as an ordered list of opaque `CSSRule`-like wrappers. The
  # cascade consumes the sheet through `cascade_text` (all rule texts
  # in document order), so insertRule/deleteRule/replaceSync and
  # `disabled` are reflected in computed styles for `<style>`-owned
  # sheets (Internal::CSS::RuleIndex re-parses on the next lookup).
  #
  #   sheet.insertRule("p { color: red }", 0);
  #   for (const r of sheet.cssRules) console.log(r.cssText);
  #
  # `href`, `media`, `title`, `type` mirror the owner node's
  # attributes when present.
  class CSSStyleSheet
    attr_reader :owner_node, :css_rules

    def initialize(owner_node:, href: nil, media: nil, title: nil, type: "text/css", source_text: nil)
      @owner_node = owner_node
      @href = href
      @media = media
      @title = title
      @type = type
      @disabled = false
      @css_rules = CSSRuleList.new
      # The owner node's CSS text at sheet creation, split into one CSSRule
      # per top-level rule (source order) so cssRules mirrors the parsed
      # sheet — selectorText / style / nested cssRules read off each slice.
      # insertRule(0) lands before them, appends after, as a real sheet would.
      Internal::CSSRuleText.split_rules(source_text).each_with_index do |slice, i|
        @css_rules.__internal_insert__(i, CSSRule.new(slice, self))
      end
    end

    def disabled
      @disabled
    end

    def disabled=(v)
      v = !!v
      changed = @disabled != v
      @disabled = v
      __internal_bump_owner_style_generation__ if changed
      v
    end

    # The sheet's full CSS text in document order — what the cascade
    # parses in place of the owner `<style>`'s raw text once the sheet
    # has been mutated through the CSSOM.
    def cascade_text
      @css_rules.map(&:css_text).join("\n")
    end

    def href
      @href
    end

    def title
      @title
    end

    def type
      @type
    end

    def media
      @media.to_s
    end

    def parent_style_sheet
      nil
    end

    def owner_rule
      nil
    end

    # `insertRule(rule, index)` — `rule` is required; inserts a CSSRule at the
    # given position (Dommy defaults to the end). Returns the index used.
    def insert_rule(rule_text, index = nil)
      raise Bridge::TypeError, "insertRule requires a rule" if rule_text.nil?

      idx = index.nil? ? @css_rules.length : index.to_i
      raise DOMException::IndexSizeError, "out of range" if idx < 0 || idx > @css_rules.length

      @css_rules.__internal_insert__(idx, CSSRule.new(rule_text.to_s, self))
      __internal_bump_owner_style_generation__
      idx
    end

    # `deleteRule(index)` — `index` is required.
    def delete_rule(index)
      raise Bridge::TypeError, "deleteRule requires an index" if index.nil?

      idx = index.to_i
      raise DOMException::IndexSizeError, "out of range" if idx < 0 || idx >= @css_rules.length

      @css_rules.__internal_delete_at__(idx)
      __internal_bump_owner_style_generation__
      nil
    end

    # `addRule(selector, style, index)` — the legacy IE-era editing API (still
    # in CSSOM). Builds `selector { style }`, inserts it (default: at the end),
    # and returns -1. Omitted selector/style stringify to "undefined", matching
    # the spec's coercion.
    def add_rule(selector = nil, style = nil, index = nil)
      selector = selector.nil? ? "undefined" : selector.to_s
      style = style.nil? ? "undefined" : style.to_s
      idx = index.nil? ? @css_rules.length : index.to_i
      insert_rule("#{selector} { #{style} }", idx)
      -1
    end

    # `removeRule(index = 0)` — the legacy alias for deleteRule (its index
    # defaults to 0, unlike deleteRule's required argument).
    def remove_rule(index = 0)
      delete_rule(index.nil? ? 0 : index)
    end

    # `replaceSync(text)` — replace all rules with a single rule blob
    # (no parsing — we keep it as one opaque entry).
    def replace_sync(text)
      @css_rules.__internal_clear__
      @css_rules.__internal_insert__(0, CSSRule.new(text.to_s, self)) unless text.to_s.empty?
      __internal_bump_owner_style_generation__
      nil
    end

    # `replace(text)` — spec returns a Promise resolved with self.
    # We can't return a JS-bridge Promise from here without a Window,
    # so we mirror the sync behavior and return self.
    def replace(text)
      replace_sync(text)
      self
    end

    def __js_get__(key)
      case key
      when "cssRules", "rules"
        @css_rules
      when "disabled"
        @disabled
      when "href"
        @href
      when "media"
        media
      when "title"
        @title
      when "type"
        @type
      when "ownerNode"
        @owner_node
      when "parentStyleSheet"
        parent_style_sheet
      when "ownerRule"
        owner_rule
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "disabled"
        self.disabled = value
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[insertRule deleteRule addRule removeRule replaceSync replace]
    def __js_call__(method, args)
      case method
      when "insertRule"
        insert_rule(args[0], args[1])
      when "deleteRule"
        delete_rule(args[0])
      when "addRule"
        add_rule(args[0], args[1], args[2])
      when "removeRule"
        remove_rule(args[0])
      when "replaceSync"
        replace_sync(args[0])
      when "replace"
        replace(args[0])
      end
    end

    # A child CSSRule whose text changed (e.g. `rule.style.color = ...`)
    # invalidates the owner document's computed style the same way
    # insertRule/deleteRule do — its rebuilt cssText feeds `cascade_text`.
    def __internal_notify_rule_changed__
      __internal_bump_owner_style_generation__
    end

    private

    # CSSOM mutations must invalidate the owner document's computed-style
    # cache — the rule index re-reads `cascade_text` on the next lookup.
    def __internal_bump_owner_style_generation__
      doc = @owner_node.respond_to?(:owner_document) ? @owner_node.owner_document : nil
      doc.__internal_bump_style_generation__ if doc.respond_to?(:__internal_bump_style_generation__)
      nil
    end
  end

  # `CSSRuleList` — indexed list of CSSRule, returned by
  # `sheet.cssRules`. Live: mutations to the owning sheet are visible.
  class CSSRuleList
    include Enumerable

    def initialize
      @rules = []
    end

    def length
      @rules.length
    end

    alias size length

    def item(index)
      i = index.to_i
      return nil if i < 0 || i >= @rules.length

      @rules[i]
    end

    def [](index)
      item(index)
    end

    def each(&blk)
      @rules.each(&blk)
    end

    def to_a
      @rules.dup
    end

    def __internal_insert__(index, rule)
      @rules.insert(index, rule)
    end

    def __internal_delete_at__(index)
      @rules.delete_at(index)
    end

    def __internal_clear__
      @rules.clear
    end

    def __js_get__(key)
      case key
      when "length"
        length
      else
        if key.is_a?(Integer) || key.to_s.match?(/\A\d+\z/)
          item(key.to_i)
        end
      end
    end

    include Bridge::Methods
    js_methods %w[item]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end

  # `CSSStyleRule#style` — a live, mutable CSSStyleDeclaration backed by a
  # rule's declaration block. Reads come from the parsed block; every write
  # reserializes the block and hands it back to the owning CSSRule, which
  # rebuilds its cssText and invalidates the document's computed-style cache.
  class RuleStyleDeclaration
    include Enumerable

    def initialize(rule, body_text)
      @rule = rule
      @props = parse(body_text)
    end

    def get_property_value(name)
      entry = @props[name.to_s]
      entry ? entry[:value] : ""
    end

    def get_property_priority(name)
      entry = @props[name.to_s]
      entry ? entry[:priority] : ""
    end

    def set_property(name, value, priority = nil)
      key = name.to_s
      if value.nil? || value.to_s.empty?
        @props.delete(key)
      else
        important = priority.to_s.downcase == "important" ? "important" : ""
        @props[key] = {value: value.to_s, priority: important}
      end
      flush!
      nil
    end

    def remove_property(name)
      removed = @props.delete(name.to_s)
      flush!
      removed ? removed[:value] : ""
    end

    def [](key)
      key.is_a?(Integer) ? @props.keys[key].to_s : get_property_value(key)
    end

    def []=(name, value)
      set_property(name, value)
    end

    def length
      @props.size
    end

    def item(index)
      @props.keys[index.to_i].to_s
    end

    def css_text
      @props.map do |name, entry|
        important = entry[:priority] == "important" ? " !important" : ""
        "#{name}: #{entry[:value]}#{important};"
      end.join(" ")
    end

    def css_text=(text)
      @props = parse(text)
      flush!
    end

    def each(&blk)
      @props.keys.each(&blk)
    end

    # camelCase / snake_case property accessors (`style.backgroundColor`).
    def method_missing(name, *args)
      str = name.to_s
      if str.end_with?("=")
        set_property(css_name(str[0..-2]), args.first)
      elsif args.empty?
        get_property_value(css_name(str))
      else
        super
      end
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    def __js_get__(key)
      case key
      when "cssText" then css_text
      when "length" then length
      when "parentRule" then @rule
      else
        if key.is_a?(Integer) || key.to_s.match?(/\A\d+\z/)
          self[key.to_i]
        else
          get_property_value(css_name(key.to_s))
        end
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText" then self.css_text = value
      else set_property(css_name(key.to_s), value)
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[getPropertyValue getPropertyPriority setProperty removeProperty item]
    def __js_call__(method, args)
      case method
      when "getPropertyValue" then get_property_value(args[0])
      when "getPropertyPriority" then get_property_priority(args[0])
      when "setProperty" then set_property(args[0], args[1], args[2])
      when "removeProperty" then remove_property(args[0])
      when "item" then item(args[0].to_i)
      end
    end

    private

    def css_name(name)
      str = name.to_s
      return str if str.start_with?("--")

      str.include?("_") ? str.tr("_", "-") : str.gsub(/[A-Z]/) { "-#{Regexp.last_match(0).downcase}" }
    end

    # Parse a declaration block into ordered { name => {value:, priority:} },
    # reusing the cascade's declaration parser (same normalization the cascade
    # sees) so reads agree with computed style.
    def parse(body_text)
      Internal::CSS::Parser.parse_declarations(body_text.to_s).each_with_object({}) do |decl, out|
        out[decl.name] = {value: decl.value, priority: decl.important ? "important" : ""}
      end
    end

    def flush!
      @rule.__internal_rebuild_from_style__(css_text)
    end
  end

  # `CSSRule` — one parsed stylesheet rule. `cssText` round-trips the source
  # slice verbatim until the rule is mutated. The CSSOM subclass hierarchy
  # (CSSStyleRule / CSSMediaRule / …) is collapsed into this one class, which
  # exposes the accessors per `type`: `selectorText` + `style` for style
  # rules, `conditionText` + `cssRules` for grouping rules (@media/@supports).
  # The selector text and declaration block are derived lazily with
  # Internal::CSSRuleText (a light scanner; the cascade's correctness still
  # comes from lexbor).
  class CSSRule
    STYLE_RULE = 1
    CHARSET_RULE = 2
    IMPORT_RULE = 3
    MEDIA_RULE = 4
    FONT_FACE_RULE = 5
    PAGE_RULE = 6
    KEYFRAMES_RULE = 7
    KEYFRAME_RULE = 8
    SUPPORTS_RULE = 12

    AT_RULE_TYPES = {
      "media" => MEDIA_RULE, "supports" => SUPPORTS_RULE, "import" => IMPORT_RULE,
      "charset" => CHARSET_RULE, "font-face" => FONT_FACE_RULE, "page" => PAGE_RULE,
      "keyframes" => KEYFRAMES_RULE
    }.freeze

    GROUPING_TYPES = [MEDIA_RULE, SUPPORTS_RULE].freeze

    attr_reader :parent_style_sheet

    def initialize(css_text, parent_style_sheet = nil)
      @css_text = css_text.to_s
      @parent_style_sheet = parent_style_sheet
    end

    def css_text
      @css_text
    end

    def css_text=(v)
      @css_text = v.to_s
      invalidate!
    end

    def type
      keyword = Internal::CSSRuleText.at_keyword(prelude)
      keyword ? AT_RULE_TYPES.fetch(keyword, STYLE_RULE) : STYLE_RULE
    end

    def style_rule?
      type == STYLE_RULE
    end

    def grouping?
      GROUPING_TYPES.include?(type)
    end

    # CSSStyleRule#selectorText — the rule's selector list ("" for at-rules).
    def selector_text
      style_rule? ? prelude : ""
    end

    def selector_text=(value)
      return unless style_rule?

      @selector = value.to_s
      rebuild_css_text!
    end

    # CSSStyleRule#style — a live, mutable declaration block. nil for at-rules
    # (matching the absent `style` member on CSSMediaRule etc.). Writes
    # reserialize cssText and invalidate the document's computed-style cache.
    def style
      return nil unless style_rule?

      @style ||= RuleStyleDeclaration.new(self, Internal::CSSRuleText.split_rule(@css_text).last)
    end

    # CSSGroupingRule#cssRules — the nested rules of an @media/@supports block.
    def css_rules
      return nil unless grouping?

      @css_rules ||= begin
        list = CSSRuleList.new
        Internal::CSSRuleText.split_rules(body).each_with_index do |slice, i|
          list.__internal_insert__(i, CSSRule.new(slice, @parent_style_sheet))
        end
        list
      end
    end

    # CSSConditionRule#conditionText — the condition text after the at-keyword.
    def condition_text
      grouping? ? prelude.sub(/\A@[-a-z]+/i, "").strip : ""
    end

    # CSSMediaRule#media — a live MediaList over the @media condition. nil for
    # non-media rules. Mutations rebuild the rule's prelude and reflow the
    # cascade.
    def media
      return nil unless type == MEDIA_RULE

      @media_list ||= MediaList.new(condition_text, on_change: method(:__internal_set_media__))
    end

    def parent_rule
      nil
    end

    # Called by RuleStyleDeclaration after a property write: rebuild cssText
    # from the (possibly new) selector and declaration block.
    def __internal_rebuild_from_style__(block_text)
      @selector ||= prelude
      @css_text = block_text.empty? ? "#{@selector} {}" : "#{@selector} { #{block_text} }"
      @parent_style_sheet&.__internal_notify_rule_changed__
      nil
    end

    # Called by the MediaList when its media text changes: rebuild the @media
    # prelude (keeping the block body) and reflow the cascade.
    def __internal_set_media__(media_text)
      @css_text = "@media #{media_text} { #{body} }"
      @prelude = nil
      @media_list = nil
      @parent_style_sheet&.__internal_notify_rule_changed__
      nil
    end

    def __js_get__(key)
      case key
      when "cssText" then @css_text
      when "type" then type
      when "selectorText" then selector_text
      when "style" then style
      when "cssRules" then css_rules
      when "conditionText" then grouping? ? condition_text : nil
      when "media" then media
      when "parentStyleSheet" then @parent_style_sheet
      when "parentRule" then parent_rule
      when "STYLE_RULE" then STYLE_RULE
      when "MEDIA_RULE" then MEDIA_RULE
      when "IMPORT_RULE" then IMPORT_RULE
      when "FONT_FACE_RULE" then FONT_FACE_RULE
      when "PAGE_RULE" then PAGE_RULE
      when "KEYFRAMES_RULE" then KEYFRAMES_RULE
      when "KEYFRAME_RULE" then KEYFRAME_RULE
      when "SUPPORTS_RULE" then SUPPORTS_RULE
      when "CHARSET_RULE" then CHARSET_RULE
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText" then self.css_text = value
      when "selectorText" then self.selector_text = value
      when "media"
        # CSSMediaRule#media is settable with a media-text string.
        __internal_set_media__(value.to_s) if type == MEDIA_RULE
      else
        # Signal "not a host property" so the bridge keeps the assignment as a
        # JS-side expando (WebIDL platform objects allow expandos; WPT's
        # [SameObject] tests stash a marker on cssRules[i] and read it back).
        return Bridge::UNHANDLED
      end

      nil
    end

    private

    # The rule prelude (selector list or at-rule keyword + condition),
    # memoized; recomputed after css_text changes.
    def prelude
      @prelude ||= Internal::CSSRuleText.split_rule(@css_text).first
    end

    # The block body (text between the outermost braces), or "" when absent.
    def body
      Internal::CSSRuleText.split_rule(@css_text).last.to_s
    end

    def rebuild_css_text!
      @css_text = body.strip.empty? ? "#{@selector} {}" : "#{@selector} { #{body.strip} }"
      @prelude = nil
      @parent_style_sheet&.__internal_notify_rule_changed__
    end

    # Drop derived state after cssText is replaced wholesale.
    def invalidate!
      @prelude = nil
      @selector = nil
      @style = nil
      @css_rules = nil
      @media_list = nil
    end
  end

  # `MediaList` — the CSSOM list of comma-separated media queries behind
  # `CSSMediaRule#media` (and `<style>`/`<link>`/`CSSStyleSheet#media`).
  # Indexed, with mediaText/append/delete editing; `on_change` (optional) is
  # called with the new media text after any mutation so the owner can persist
  # it.
  class MediaList
    def initialize(media_text = "", on_change: nil)
      @items = parse(media_text)
      @on_change = on_change
    end

    def length
      @items.length
    end

    def item(index)
      i = index.to_i
      i.negative? || i >= @items.length ? nil : @items[i]
    end

    def media_text
      @items.join(", ")
    end

    def media_text=(text)
      @items = parse(text)
      notify
    end

    # css-mediaqueries: appendMedium is a no-op when the medium is already
    # present (case-insensitively); deleteMedium removes every match.
    def append_medium(medium)
      medium = medium.to_s.strip
      return if medium.empty? || @items.any? { |existing| existing.casecmp(medium).zero? }

      @items << medium
      notify
    end

    def delete_medium(medium)
      medium = medium.to_s.strip
      @items.reject! { |existing| existing.casecmp(medium).zero? }
      notify
    end

    def to_s
      media_text
    end

    def __js_get__(key)
      case key
      when "length" then length
      when "mediaText" then media_text
      else
        item(key.to_i) if key.is_a?(Integer) || key.to_s.match?(/\A\d+\z/)
      end
    end

    def __js_set__(key, value)
      return Bridge::UNHANDLED unless key == "mediaText"

      # [LegacyNullToEmptyString]: `media.mediaText = null` clears it.
      self.media_text = value.nil? ? "" : value
      nil
    end

    include Bridge::Methods
    js_methods %w[item appendMedium deleteMedium toString]
    def __js_call__(method, args)
      case method
      when "item" then item(args[0])
      when "appendMedium" then append_medium(args[0])
      when "deleteMedium" then delete_medium(args[0])
      when "toString" then to_s
      end
    end

    private

    def parse(text)
      text.to_s.split(",").map(&:strip).reject(&:empty?)
    end

    def notify
      @on_change&.call(media_text)
    end
  end

  # `window.CSS` namespace object — `escape()` for safe selector building
  # (used by Turbo and friends) and `supports()` backed by the @supports
  # condition evaluator.
  class CSSNamespace
    def __js_get__(_key) = Bridge::ABSENT # method-only; any property read is absent
    def __js_set__(_key, _value) = Bridge::UNHANDLED

    include Bridge::Methods
    js_methods %w[escape supports]
    def __js_call__(method, args)
      case method
      when "escape"
        self.class.escape(args[0])
      when "supports"
        supports?(args)
      end
    end

    # CSS.supports(property, value) checks one declaration; CSS.supports(
    # conditionText) evaluates a full <supports-condition>. Both go through the
    # same optimistic evaluator the cascade uses for @supports.
    def supports?(args)
      if args.length >= 2 && !args[1].nil?
        Internal::CSS::Supports.supports_declaration?(args[0], args[1])
      else
        Internal::CSS::Supports.match?(args[0])
      end
    end

    # CSSOM `CSS.escape` — escape a string for use as an identifier in a
    # selector. Follows the spec's char rules closely enough for selectors.
    def self.escape(value)
      str = value.to_s
      out = +""
      str.each_char.with_index do |ch, i|
        code = ch.ord
        if code.zero?
          out << "\uFFFD"
        elsif (code >= 0x01 && code <= 0x1F) || code == 0x7F ||
              (i.zero? && code >= 0x30 && code <= 0x39) ||
              (i == 1 && code >= 0x30 && code <= 0x39 && str[0] == "-")
          out << "\\#{code.to_s(16)} "
        elsif code >= 0x80 || code == 0x2D || code == 0x5F ||
              (code >= 0x30 && code <= 0x39) ||
              (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A)
          out << ch
        else
          out << "\\#{ch}"
        end
      end
      out
    end
  end
end
