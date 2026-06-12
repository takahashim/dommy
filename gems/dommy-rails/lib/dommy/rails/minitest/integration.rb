module Dommy
  module Rails
    module Minitest
      module Integration
        def dom
          body = dom_html_source.to_s
          return @dommy_rails_dom if defined?(@dommy_rails_dom_source) && @dommy_rails_dom_source == body

          @dommy_rails_dom_source = body
          @dommy_rails_dom = Dommy.parse(body).document
        end

        include Dommy::Minitest::Assertions
        include Dommy::Rails::Minitest::Assertions

        private

        def dom_html_source
          if respond_to?(:response) && response.respond_to?(:body) && response.body
            response.body
          elsif respond_to?(:rendered) && rendered
            rendered
          elsif respond_to?(:message) && (html = html_from_mail(message))
            html
          else
            raise "Dommy::Rails::Minitest::Integration could not find HTML. Expected response.body, rendered, or message.html_part."
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
