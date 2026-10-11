# frozen_string_literal: true

require_relative "matchers"

module Dommy
  module Rails
    module RSpec
      # Matchers for a mail object (`ActionMailer::Base.deliveries.last`, a
      # mailer's return value): its HTML part's links and text, and its plain
      # text part. Kept apart from Matchers, whose DOM matchers share names
      # with Capybara's (`have_title`, `have_link`), so a suite can include
      # these in its browser and system specs without hiding Capybara's.
      module MailMatchers
        def have_html_link(text = nil, href: nil, count: nil)
          HaveHtmlLink.new(text, href: href, count: count)
        end

        def have_html_text(text)
          HaveHtmlText.new(text)
        end

        def have_plain_text(text)
          HavePlainText.new(text)
        end

        class HaveHtmlLink
          include Matchers::Negatable

          def initialize(text, href:, count:)
            @text = text
            @href = href
            @count = count
          end

          def matches?(mail)
            @document = Dommy::Rails::MailPart.html_document(mail)
            return false unless @document

            @matched = Dommy::Rails::PageInspector.links(@document, text: @text, href: @href)
            Dommy::Internal::DomMatching.count_matches?(@matched.size, @count)
          end

          def description
            "have HTML link"
          end

          def failure_message
            return "expected mail to have an HTML part" unless @document

            "expected mail HTML to contain link, found #{@matched.size}"
          end

          def failure_message_when_negated
            "expected mail HTML not to contain link"
          end
        end

        class HaveHtmlText
          include Matchers::Negatable

          def initialize(text)
            @text = text
          end

          def matches?(mail)
            @document = Dommy::Rails::MailPart.html_document(mail)
            return false unless @document

            @actual = Dommy::Internal::DomMatching.text_of(@document)
            Dommy::Internal::DomMatching.text_matches?(@actual, @text)
          end

          def description
            "have HTML text #{@text.inspect}"
          end

          def failure_message
            return "expected mail to have an HTML part" unless @document

            "expected mail HTML to include #{@text.inspect}, got #{@actual.inspect}"
          end

          def failure_message_when_negated
            "expected mail HTML not to include #{@text.inspect}"
          end
        end

        class HavePlainText
          include Matchers::Negatable

          def initialize(text)
            @text = text
          end

          def matches?(mail)
            @actual = Dommy::Rails::MailPart.plain_body(mail).to_s
            Dommy::Internal::DomMatching.text_matches?(@actual, @text)
          end

          def description
            "have plain text #{@text.inspect}"
          end

          def failure_message
            "expected mail plain text to include #{@text.inspect}, got #{@actual.inspect}"
          end

          def failure_message_when_negated
            "expected mail plain text not to include #{@text.inspect}"
          end
        end
      end
    end
  end
end
