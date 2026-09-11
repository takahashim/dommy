# frozen_string_literal: true

module Capybara
  module Dommy
    # What one `accept_modal` / `dismiss_modal` block is waiting for, and what
    # it saw. A native dialog is synchronous in Dommy, so the expectation is
    # installed before the triggering block runs and answers the dialog the
    # block opens.
    class ModalExpectation
      attr_reader :type, :text
      # The message of the dialog this expectation answered — nil while it is
      # still waiting, which is what makes it "not found" at the end of the
      # block.
      attr_reader :message

      def initialize(type:, accept:, text: nil, with: nil)
        @type = type.to_sym
        @accept = accept
        @text = text
        @with = with
        @message = nil
        @actual = nil
      end

      def matches?(type, message)
        @type == type && text_matches?(message)
      end

      def answered? = !@message.nil?

      # Record that this dialog is the one, and answer it: a confirm with the
      # accept/dismiss decision, a prompt with the text to type (`with:`, else
      # what the page offered) or nil when dismissed. An alert has no answer.
      def answer(message, default_value)
        @message = message
        case @type
        when :confirm then @accept
        when :prompt then @accept ? (@with || default_value) : nil
        end
      end

      # A dialog this expectation did not want. Remembered for the error at the
      # end of the block, which says what turned up instead.
      def saw(type, message)
        @actual = {type: type, message: message}
        nil
      end

      def not_found_message
        if @actual
          "Unable to find #{@type} dialog with #{@text.inspect} - found " \
            "#{@actual[:type]} dialog with #{@actual[:message].inspect} instead."
        else
          "Unable to find #{@type} dialog#{@text ? " with #{@text.inspect}" : ""}"
        end
      end

      private

      def text_matches?(message)
        return true if @text.nil?

        pattern = @text.is_a?(Regexp) ? @text : Regexp.new(Regexp.escape(@text.to_s))
        pattern.match?(message)
      end
    end

    # The expectations currently in scope, innermost first, as the dialog
    # handler a Dommy Window asks (it calls `#call`).
    #
    # A stack, because Capybara expresses nested confirms as nested helper
    # blocks while the page opens them sequentially in one JS call stack:
    # consuming the inner expectation exposes the outer answer to the next
    # confirm immediately.
    class ModalStack
      def initialize
        @expectations = []
      end

      def empty? = @expectations.empty?

      def push(expectation)
        @expectations << expectation
        expectation
      end

      # By identity: two helper blocks with the same arguments build EQUAL
      # expectations, and removing by value would drop the caller's alongside
      # this one.
      def delete(expectation)
        @expectations.delete_if { |e| e.equal?(expectation) }
        nil
      end

      # The dialog handler protocol: answer the dialog, or return
      # DIALOG_UNANSWERED to leave it to the Window's headless default. An
      # expectation that does not want this dialog remembers it (so the block
      # can say what turned up instead) and declines rather than answering.
      def call(type, message, default_value)
        expectation = @expectations.last
        return ::Dommy::Window::DIALOG_UNANSWERED if expectation.nil?

        unless expectation.matches?(type, message)
          expectation.saw(type, message)
          return ::Dommy::Window::DIALOG_UNANSWERED
        end

        answer = expectation.answer(message, default_value)
        delete(expectation)
        answer
      end
    end
  end
end
