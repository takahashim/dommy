# frozen_string_literal: true

module Dommy
  module Rails
    # Extracts HTML / plain-text bodies from Mail-like objects
    # (multipart or single-part).
    module MailPart
      module_function

      def html_body(mail)
        part_body(mail, :html_part)
      end

      def plain_body(mail)
        part_body(mail, :text_part)
      end

      def html_document(mail)
        body = html_body(mail)
        body ? Dommy.parse(body).document : nil
      end

      def part_body(mail, part_name)
        part = mail.public_send(part_name) if mail.respond_to?(part_name)
        return part.body.to_s if part

        mail.body.to_s if mail.respond_to?(:body)
      end
      private_class_method :part_body
    end
  end
end
