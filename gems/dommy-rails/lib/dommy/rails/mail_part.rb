# frozen_string_literal: true

module Dommy
  module Rails
    # Extracts HTML / plain-text bodies from Mail-like objects
    # (multipart or single-part).
    module MailPart
      module_function

      def html_body(mail)
        if mail.respond_to?(:html_part) && mail.html_part
          mail.html_part.body.to_s
        elsif mail.respond_to?(:body)
          mail.body.to_s
        end
      end

      def plain_body(mail)
        if mail.respond_to?(:text_part) && mail.text_part
          mail.text_part.body.to_s
        elsif mail.respond_to?(:body)
          mail.body.to_s
        end
      end

      def html_document(mail)
        body = html_body(mail)
        body ? Dommy.parse(body).document : nil
      end
    end
  end
end
