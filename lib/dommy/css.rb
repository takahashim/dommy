# frozen_string_literal: true

module Dommy
  # `CSSStyleSheet` — stub implementation. Dommy has no CSS parser
  # nor a render tree, so we don't interpret rule text; the sheet
  # acts as an ordered list of opaque `CSSRule`-like wrappers.
  #
  # Useful for code that does:
  #
  #   sheet.insertRule("p { color: red }", 0);
  #   for (const r of sheet.cssRules) console.log(r.cssText);
  #
  # `disabled` is honored as state. `href`, `media`, `title`, `type`
  # mirror the owner node's attributes when present.
  class CSSStyleSheet
    attr_reader :owner_node, :css_rules

    def initialize(owner_node:, href: nil, media: nil, title: nil, type: "text/css")
      @owner_node = owner_node
      @href = href
      @media = media
      @title = title
      @type = type
      @disabled = false
      @css_rules = CSSRuleList.new
    end

    def disabled
      @disabled
    end

    def disabled=(v)
      @disabled = !!v
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

    # `insertRule(rule_text, index)` — appends an opaque CSSRule at the
    # given position (default: end). Returns the index used.
    def insert_rule(rule_text, index = nil)
      idx = index.nil? ? @css_rules.length : index.to_i
      raise DOMException::IndexSizeError, "out of range" if idx < 0 || idx > @css_rules.length

      @css_rules.__insert__(idx, CSSRule.new(rule_text.to_s, self))
      idx
    end

    def delete_rule(index)
      idx = index.to_i
      raise DOMException::IndexSizeError, "out of range" if idx < 0 || idx >= @css_rules.length

      @css_rules.__delete_at__(idx)
      nil
    end

    # `replaceSync(text)` — replace all rules with a single rule blob
    # (no parsing — we keep it as one opaque entry).
    def replace_sync(text)
      @css_rules.__clear__
      return nil if text.to_s.empty?

      @css_rules.__insert__(0, CSSRule.new(text.to_s, self))
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
      end
    end

    def __js_set__(key, value)
      case key
      when "disabled"
        self.disabled = value
      end

      nil
    end

    def __js_call__(method, args)
      case method
      when "insertRule"
        insert_rule(args[0], args[1])
      when "deleteRule"
        delete_rule(args[0])
      when "replaceSync"
        replace_sync(args[0])
      when "replace"
        replace(args[0])
      end
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

    def __insert__(index, rule)
      @rules.insert(index, rule)
    end

    def __delete_at__(index)
      @rules.delete_at(index)
    end

    def __clear__
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

    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      end
    end
  end

  # `CSSRule` — opaque wrapper over the raw rule text. Real engines
  # have a subclass hierarchy (CSSStyleRule, CSSMediaRule, etc.), but
  # without a CSS parser we keep one minimal type that round-trips
  # the source text.
  class CSSRule
    STYLE_RULE = 1
    CHARSET_RULE = 2
    IMPORT_RULE = 3
    MEDIA_RULE = 4
    FONT_FACE_RULE = 5
    PAGE_RULE = 6
    KEYFRAMES_RULE = 7
    KEYFRAME_RULE = 8

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
    end

    # We don't parse, so report the generic STYLE_RULE type.
    def type
      STYLE_RULE
    end

    def parent_rule
      nil
    end

    def __js_get__(key)
      case key
      when "cssText"
        @css_text
      when "type"
        type
      when "parentStyleSheet"
        @parent_style_sheet
      when "parentRule"
        parent_rule
      when "STYLE_RULE"
        STYLE_RULE
      when "MEDIA_RULE"
        MEDIA_RULE
      when "IMPORT_RULE"
        IMPORT_RULE
      when "FONT_FACE_RULE"
        FONT_FACE_RULE
      when "PAGE_RULE"
        PAGE_RULE
      when "KEYFRAMES_RULE"
        KEYFRAMES_RULE
      when "KEYFRAME_RULE"
        KEYFRAME_RULE
      when "CHARSET_RULE"
        CHARSET_RULE
      end
    end

    def __js_set__(key, value)
      case key
      when "cssText"
        self.css_text = value
      end

      nil
    end
  end
end
