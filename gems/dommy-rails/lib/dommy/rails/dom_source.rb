# frozen_string_literal: true

require_relative "mail_part"

module Dommy
  module Rails
    # Shared implementation of the `dom` helper for the Minitest and
    # RSpec integration modules: locates the HTML source on the test
    # context (response / rendered / mail) and memoizes the parsed
    # document per source string.
    module DomSource
      def dom
        source = dom_html_source.to_s
        return @dommy_rails_dom if defined?(@dommy_rails_dom_source) && @dommy_rails_dom_source == source

        @dommy_rails_dom_source = source
        @dommy_rails_dom = Dommy.parse(source).document
      end

      private

      def dom_html_source
        if respond_to?(:response) && response.respond_to?(:body) && response.body
          response.body
        elsif respond_to?(:rendered) && rendered
          rendered
        elsif respond_to?(:message) && (html = MailPart.html_body(message))
          html
        else
          raise "Dommy::Rails could not find HTML for `dom`. Expected response.body, rendered, or message.html_part."
        end
      end
    end
  end
end
