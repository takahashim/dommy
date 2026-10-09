# frozen_string_literal: true

require_relative "parser"
require_relative "media_query"
require_relative "../bounded_cache"

module Dommy
  module Internal
    module CSS
      class RuleIndex
        # What a document's rule index is built from, read off the document:
        # its author sheets' parsed rules, the media environment their @media
        # blocks and `media` attributes are judged against, the quirks mode
        # the id and class buckets fold by, the host's @import resolver, and
        # whether it has shadow roots (whose sheets index against the tree).
        # Two reads that are the same build the same plain index — see
        # RuleIndex.build.
        #
        # An @import is not read again for the same sheets: a browser loads
        # an imported sheet when its parent sheet is parsed, and the same
        # parsed sheets mean the same parse.
        class Inputs
          # Parsed-sheet cache (text => rules), module-level like the selector
          # AST cache: an invalidation rebuilds the index far more often than
          # any sheet's text changes, so the parse is reused. The parse results
          # are read-only value objects, safe to share between builds — and the
          # same object for the same text is what lets #same_as? compare sheets
          # by identity. (Hash dup+freezes unfrozen String keys, so a later
          # mutation of the source text can't corrupt an entry.)
          PARSE_CACHE = Internal::BoundedCache.new(64)

          def self.parse(text)
            PARSE_CACHE.fetch(text) { Parser.parse(text) }
          rescue Parser::Unavailable
            # A missing makiri is not a malformed sheet: it means CSS is
            # unavailable at all, which the caller reports rather than swallows.
            raise
          rescue StandardError
            # Lexbor recovers from bad CSS itself, so reaching here means the
            # normalization above it broke on a shape it did not expect. One
            # sheet is dropped rather than the page.
            []
          end

          # The media environment of the document's window — or the default
          # (1280x720) for windowless documents (fragments, DOMParser output).
          # Live: a resize changes it in place, which is why #same_as? compares
          # the values read at build time.
          attr_reader :environment

          def initialize(document)
            @document = document
            view = document.respond_to?(:default_view) ? document.default_view : nil
            @environment = (view && view.media_environment) || MediaQuery::DEFAULT
            @environment_values = @environment.to_a
            @quirks = document.respond_to?(:quirks_mode?) && document.quirks_mode?
            @import_resolver = document.respond_to?(:css_import_resolver) ? document.css_import_resolver : nil
            @shadow_roots = document.respond_to?(:__internal_all_shadow_roots__) &&
                            !document.__internal_all_shadow_roots__.empty?
          end

          # Author sheets in document order. <style> and <link rel=stylesheet>
          # are walked together so their relative order is preserved (it breaks
          # cascade ties). A `media` attribute gates the whole sheet (same
          # evaluator as @media); `disabled` mutes it.
          def sheets
            @sheets ||= sheet_elements.filter_map do |element|
              media = element.__internal_attribute_value__("media").to_s.strip
              next nil unless media.empty? || MediaQuery.match?(media, @environment)

              link_element?(element) ? link_sheet_rules(element) : style_element_rules(element)
            end
          end

          # Whether an index built from `other` would come out as one built from
          # these: the same parsed sheets in the same order, the same media
          # environment, quirks mode and import resolver, and no shadow roots
          # on either side.
          def same_as?(other)
            return false if @shadow_roots || other.shadow_roots?
            return false unless @environment_values == other.environment_values && @quirks == other.quirks?
            return false unless @import_resolver.equal?(other.import_resolver)

            mine = sheets
            theirs = other.sheets
            mine.size == theirs.size && mine.each_index.all? { |i| mine[i].equal?(theirs[i]) }
          end

          protected

          attr_reader :environment_values, :import_resolver

          def quirks? = @quirks
          def shadow_roots? = @shadow_roots

          private

          def link_element?(element)
            element.local_name.to_s.casecmp("link").zero?
          end

          def sheet_elements
            if @document.respond_to?(:__internal_style_sheet_elements__)
              @document.__internal_style_sheet_elements__
            else
              @document.query_selector_all("style, link").to_a
            end
          end

          # A <link rel=stylesheet> contributes only once a host environment has
          # filled its CSS in (Dommy fetches nothing). The filled sheet is read
          # through `cascade_text`, exactly like a <style>'s CSSOM sheet.
          def link_sheet_rules(element)
            return nil unless element.respond_to?(:__internal_stylesheet_for_cascade__)

            sheet = element.__internal_stylesheet_for_cascade__
            return nil if sheet.nil? || sheet.disabled

            self.class.parse(sheet.cascade_text)
          end

          # When a CSSStyleSheet was instantiated for the <style> (and isn't
          # stale), its CSSOM state wins: `cascade_text` carries insertRule edits
          # and `disabled` mutes it. Otherwise the element's text is parsed.
          def style_element_rules(element)
            sheet = element.respond_to?(:__internal_instantiated_sheet__) && element.__internal_instantiated_sheet__
            if sheet
              return nil if sheet.disabled

              self.class.parse(sheet.cascade_text)
            else
              self.class.parse(element.text_content.to_s)
            end
          end
        end
      end
    end
  end
end
