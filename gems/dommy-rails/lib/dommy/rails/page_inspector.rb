# frozen_string_literal: true

require "dommy/internal/dom_matching"
require "dommy/internal/element_matching"
require_relative "url_matcher"

module Dommy
  module Rails
    module PageInspector
      module_function

      def title_matches?(document, expected)
        Dommy::Internal::DomMatching.text_matches?(document.title.to_s, expected, exact: true)
      end

      def meta_matches?(document, name: nil, property: nil, content: nil)
        document.query_selector_all("meta").to_a.any? do |meta|
          (name.nil? || meta.get_attribute("name").to_s == name.to_s) &&
            (property.nil? || meta.get_attribute("property").to_s == property.to_s) &&
            (content.nil? || meta.get_attribute("content").to_s == content.to_s)
        end
      end

      def csrf_meta_tags?(document)
        param = document.query_selector("meta[name='csrf-param']")
        token = document.query_selector("meta[name='csrf-token']")
        present_content?(param) && present_content?(token)
      end

      def authenticity_token?(document)
        document.query_selector_all("input[type='hidden'][name='authenticity_token']").to_a.any? do |input|
          input.get_attribute("value").to_s != ""
        end
      end

      def links(document, text: nil, href: nil)
        Dommy::Internal::ElementMatching.find_links(document, text: text, href: href && UrlMatcher.new(href))
      end

      def turbo_frames(document, id = nil, text: nil)
        frames = document.query_selector_all("turbo-frame").to_a
        frames = frames.select { |frame| frame.get_attribute("id").to_s == id.to_s } if id
        frames = frames.select { |frame| Dommy::Internal::DomMatching.text_matches?(frame.text_content, text) } if text
        frames
      end

      def xpath_matches(document, expression, text: nil)
        nodes = document.xpath(expression).to_a
        nodes = nodes.select { |node| Dommy::Internal::DomMatching.text_matches?(node.text_content, text) } if text
        nodes
      end

      def checkable_fields(document, name: nil, checked: nil)
        Dommy::Internal::ElementMatching.find_checkable_fields(document, name: name, checked: checked)
      end

      def selects(document, name: nil, label: nil)
        Dommy::Internal::ElementMatching.find_selects(document, name: name, label: label)
      end

      def present_content?(element)
        element && element.get_attribute("content").to_s != ""
      end
    end
  end
end
