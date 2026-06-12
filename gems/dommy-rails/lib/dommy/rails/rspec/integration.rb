# frozen_string_literal: true

module Dommy
  module Rails
    module RSpec
      module Integration
        # Include order matters: Rails::RSpec::Matchers comes last so its
        # Rails-specific `have_link` (URL-normalizing `href:` matching)
        # deliberately overrides the CapyStyleMatchers version.
        include ::Dommy::RSpec::CapyStyleMatchers
        include Dommy::Rails::RSpec::Matchers

        def dom
          source = dom_html_source
          source_string = source.to_s
          return @dommy_rails_dom if defined?(@dommy_rails_dom_source) && @dommy_rails_dom_source == source_string

          @dommy_rails_dom_source = source_string
          @dommy_rails_dom = Dommy.parse(source_string).document
        end

        private

        def dom_html_source
          if respond_to?(:response) && response.respond_to?(:body) && response.body
            response.body
          elsif respond_to?(:rendered) && rendered
            rendered
          elsif respond_to?(:message) && (html = html_from_mail(message))
            html
          else
            raise "Dommy::Rails::RSpec::Integration could not find HTML. Expected response.body, rendered, or message.html_part."
          end
        end

        def html_from_mail(mail)
          if mail.respond_to?(:html_part) && mail.html_part
            mail.html_part.body.to_s
          elsif mail.respond_to?(:body)
            mail.body.to_s
          end
        end
      end
    end
  end
end
