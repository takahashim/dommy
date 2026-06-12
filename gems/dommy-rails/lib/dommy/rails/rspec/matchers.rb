# frozen_string_literal: true

module Dommy
  module Rails
    module RSpec
      module Matchers
        def have_form(action: nil, method: nil, model: nil)
          HaveForm.new(action: action, method: method, model: model)
        end

        def have_xpath(expression, text: nil, count: nil)
          HaveXPath.new(expression, text: text, count: count)
        end

        def have_title(expected)
          HaveTitle.new(expected)
        end

        def have_meta(name: nil, property: nil, content: nil)
          HaveMeta.new(name: name, property: property, content: content)
        end

        def have_csrf_meta_tags
          HaveCsrfMetaTags.new
        end

        def have_authenticity_token
          HaveAuthenticityToken.new
        end

        def have_link(text = nil, href: nil, count: nil)
          HaveLink.new(text, href: href, count: count)
        end

        def have_turbo_frame(id = nil, text: nil, count: nil)
          HaveTurboFrame.new(id, text: text, count: count)
        end

        def have_select(name = nil, label: nil, count: nil)
          HaveSelect.new(name, label: label, count: count)
        end

        def have_checked_field(name = nil)
          HaveCheckableField.new(name, checked: true)
        end

        def have_unchecked_field(name = nil)
          HaveCheckableField.new(name, checked: false)
        end

        def have_turbo_stream(action:, target:)
          HaveTurboStream.new(action: action, target: target)
        end

        def append_turbo_stream(target)
          HaveTurboStream.new(action: "append", target: target)
        end

        def replace_turbo_stream(target)
          HaveTurboStream.new(action: "replace", target: target)
        end

        def update_turbo_stream(target)
          HaveTurboStream.new(action: "update", target: target)
        end

        def remove_turbo_stream(target)
          HaveTurboStream.new(action: "remove", target: target)
        end

        def have_stimulus_controller(name)
          HaveStimulusController.new(name)
        end

        def have_stimulus_action(action)
          HaveStimulusAction.new(action)
        end

        def have_stimulus_target(controller, target)
          HaveStimulusTarget.new(controller, target)
        end

        def have_stimulus_value(controller, key, value)
          HaveStimulusValue.new(controller, key, value)
        end

        def have_no_duplicate_ids
          HaveNoDuplicateIds.new
        end

        def have_no_invalid_aria_references
          HaveNoInvalidAriaReferences.new
        end

        def have_no_missing_form_labels
          HaveNoMissingFormLabels.new
        end

        def have_no_empty_links
          HaveNoEmptyLinks.new
        end

        def have_no_nested_interactive_elements
          HaveNoNestedInteractiveElements.new
        end

        def have_html_link(text = nil, href: nil, count: nil)
          HaveHtmlLink.new(text, href: href, count: count)
        end

        def have_html_text(text)
          HaveHtmlText.new(text)
        end

        def have_plain_text(text)
          HavePlainText.new(text)
        end

        class HaveForm
          def initialize(action:, method:, model:)
            @action = action
            @method = method
            @model = model
          end

          def matches?(actual)
            @document = MatchTarget.document(actual)
            Dommy::Rails::FormInspector.matches?(@document, action: @action, method: @method, model: @model)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have form #{criteria_description}"
          end

          def failure_message
            "expected to find form #{criteria_description}"
          end

          def failure_message_when_negated
            "expected not to find form #{criteria_description}"
          end

          private

          def criteria_description
            parts = []
            parts << "action=#{@action.inspect}" if @action
            parts << "method=#{@method.inspect}" if @method
            parts << "model=#{@model.inspect}" if @model
            parts.empty? ? "matching any criteria" : parts.join(" ")
          end
        end

        class HaveXPath
          def initialize(expression, text:, count:)
            @expression = expression
            @text = text
            @count = count
          end

          def matches?(actual)
            @matched = Dommy::Rails::PageInspector.xpath_matches(MatchTarget.document(actual), @expression, text: @text)
            Dommy::Internal::DomMatching.count_matches?(@matched.size, @count)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have XPath #{@expression.inspect}"
          end

          def failure_message
            "expected to find XPath #{@expression.inspect}, found #{@matched.size}"
          end

          def failure_message_when_negated
            "expected not to find XPath #{@expression.inspect}, found #{@matched.size}"
          end
        end

        class HaveTitle
          def initialize(expected)
            @expected = expected
          end

          def matches?(actual)
            @document = MatchTarget.document(actual)
            Dommy::Rails::PageInspector.title_matches?(@document, @expected)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have title #{@expected.inspect}"
          end

          def failure_message
            "expected title to match #{@expected.inspect}, got #{@document.title.inspect}"
          end

          def failure_message_when_negated
            "expected title not to match #{@expected.inspect}"
          end
        end

        class HaveMeta
          def initialize(name:, property:, content:)
            @name = name
            @property = property
            @content = content
          end

          def matches?(actual)
            Dommy::Rails::PageInspector.meta_matches?(MatchTarget.document(actual), name: @name, property: @property, content: @content)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have meta #{criteria_description}"
          end

          def failure_message
            "expected to find meta #{criteria_description}"
          end

          def failure_message_when_negated
            "expected not to find meta #{criteria_description}"
          end

          private

          def criteria_description
            parts = []
            parts << "name=#{@name.inspect}" if @name
            parts << "property=#{@property.inspect}" if @property
            parts << "content=#{@content.inspect}" if @content
            parts.empty? ? "matching any criteria" : parts.join(" ")
          end
        end

        class HaveCsrfMetaTags
          def matches?(actual)
            Dommy::Rails::PageInspector.csrf_meta_tags?(MatchTarget.document(actual))
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Rails CSRF meta tags"
          end

          def failure_message
            "expected to find Rails CSRF meta tags"
          end

          def failure_message_when_negated
            "expected not to find Rails CSRF meta tags"
          end
        end

        class HaveAuthenticityToken
          def matches?(actual)
            Dommy::Rails::PageInspector.authenticity_token?(MatchTarget.document(actual))
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Rails authenticity token field"
          end

          def failure_message
            "expected to find Rails authenticity token field"
          end

          def failure_message_when_negated
            "expected not to find Rails authenticity token field"
          end
        end

        class HaveLink
          def initialize(text, href:, count:)
            @text = text
            @href = href
            @count = count
          end

          def matches?(actual)
            @matched = Dommy::Rails::PageInspector.links(MatchTarget.document(actual), text: @text, href: @href)
            Dommy::Internal::DomMatching.count_matches?(@matched.size, @count)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have link"
          end

          def failure_message
            "expected to find link, found #{@matched.size}"
          end

          def failure_message_when_negated
            "expected not to find link, found #{@matched.size}"
          end
        end

        class HaveTurboFrame
          def initialize(id, text:, count:)
            @id = id
            @text = text
            @count = count
          end

          def matches?(actual, &block)
            @matched = Dommy::Rails::PageInspector.turbo_frames(MatchTarget.document(actual), @id, text: @text)
            ok = Dommy::Internal::DomMatching.count_matches?(@matched.size, @count)
            block.call(@matched.first) if ok && block && @matched.any?
            ok
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have turbo-frame#{@id ? " ##{@id}" : ""}"
          end

          def failure_message
            "expected to find turbo-frame#{@id ? " ##{@id}" : ""}, found #{@matched.size}"
          end

          def failure_message_when_negated
            "expected not to find turbo-frame#{@id ? " ##{@id}" : ""}, found #{@matched.size}"
          end
        end

        class HaveSelect
          def initialize(name, label:, count:)
            @name = name
            @label = label
            @count = count
          end

          def matches?(actual)
            @matched = Dommy::Rails::PageInspector.selects(MatchTarget.document(actual), name: @name, label: @label)
            Dommy::Internal::DomMatching.count_matches?(@matched.size, @count)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have select"
          end

          def failure_message
            "expected to find select, found #{@matched.size}"
          end

          def failure_message_when_negated
            "expected not to find select, found #{@matched.size}"
          end
        end

        class HaveCheckableField
          def initialize(name, checked:)
            @name = name
            @checked = checked
          end

          def matches?(actual)
            @matched = Dommy::Rails::PageInspector.checkable_fields(MatchTarget.document(actual), name: @name, checked: @checked)
            @matched.any?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have #{@checked ? 'checked' : 'unchecked'} field"
          end

          def failure_message
            "expected to find #{@checked ? 'checked' : 'unchecked'} field"
          end

          def failure_message_when_negated
            "expected not to find #{@checked ? 'checked' : 'unchecked'} field"
          end
        end

        class HaveTurboStream
          def initialize(action:, target:)
            @action = action
            @target = target
          end

          def matches?(actual, &block)
            stream = Dommy::Rails::TurboStream.find(MatchTarget.body(actual), action: @action, target: @target)
            block.call(Dommy::Rails::TurboStream.fragment_document(stream)) if stream && block
            !stream.nil?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have turbo-stream action=#{@action.inspect} target=#{@target.inspect}"
          end

          def failure_message
            "expected to find turbo-stream action=#{@action.inspect} target=#{@target.inspect}"
          end

          def failure_message_when_negated
            "expected not to find turbo-stream action=#{@action.inspect} target=#{@target.inspect}"
          end
        end

        class HaveStimulusController
          def initialize(name)
            @name = name
          end

          def matches?(actual)
            Dommy::Rails::Stimulus.controller?(MatchTarget.document(actual), @name)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Stimulus controller #{@name.inspect}"
          end

          def failure_message
            "expected to find element with Stimulus controller #{@name.inspect}"
          end

          def failure_message_when_negated
            "expected not to find element with Stimulus controller #{@name.inspect}"
          end
        end

        class HaveStimulusAction
          def initialize(action)
            @action = action
          end

          def matches?(actual)
            Dommy::Rails::Stimulus.action?(MatchTarget.document(actual), @action)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Stimulus action #{@action.inspect}"
          end

          def failure_message
            "expected to find element with Stimulus action #{@action.inspect}"
          end

          def failure_message_when_negated
            "expected not to find element with Stimulus action #{@action.inspect}"
          end
        end

        class HaveStimulusTarget
          def initialize(controller, target)
            @controller = controller
            @target = target
          end

          def matches?(actual)
            Dommy::Rails::Stimulus.target?(MatchTarget.document(actual), @controller, @target)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Stimulus target #{@controller.inspect}.#{@target.inspect}"
          end

          def failure_message
            "expected to find element with Stimulus target #{@controller.inspect}.#{@target.inspect}"
          end

          def failure_message_when_negated
            "expected not to find element with Stimulus target #{@controller.inspect}.#{@target.inspect}"
          end
        end

        class HaveStimulusValue
          def initialize(controller, key, value)
            @controller = controller
            @key = key
            @value = value
          end

          def matches?(actual)
            Dommy::Rails::Stimulus.value?(MatchTarget.document(actual), @controller, @key, @value)
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have Stimulus value #{@controller.inspect}.#{@key.inspect}"
          end

          def failure_message
            "expected to find element with Stimulus value #{@controller.inspect}.#{@key.inspect} = #{@value.inspect}"
          end

          def failure_message_when_negated
            "expected not to find element with Stimulus value #{@controller.inspect}.#{@key.inspect} = #{@value.inspect}"
          end
        end

        class HaveNoDuplicateIds
          def matches?(actual)
            @issues = Dommy::Rails::Lint.duplicate_ids(MatchTarget.document(actual))
            @issues.empty?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have no duplicate ids"
          end

          def failure_message
            "expected no duplicate IDs, found: #{@issues.join(', ')}"
          end

          def failure_message_when_negated
            "expected duplicate IDs"
          end
        end

        class HaveNoInvalidAriaReferences
          def matches?(actual)
            @issues = Dommy::Rails::Lint.invalid_aria_references(MatchTarget.document(actual))
            @issues.empty?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have no invalid ARIA references"
          end

          def failure_message
            "expected no invalid ARIA references, found #{@issues.size} issues"
          end

          def failure_message_when_negated
            "expected invalid ARIA references"
          end
        end

        class HaveNoMissingFormLabels
          def matches?(actual)
            @issues = Dommy::Rails::Lint.missing_form_labels(MatchTarget.document(actual))
            @issues.empty?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have no missing form labels"
          end

          def failure_message
            "expected no missing form labels, found #{@issues.size} issues"
          end

          def failure_message_when_negated
            "expected missing form labels"
          end
        end

        class HaveNoEmptyLinks
          def matches?(actual)
            @issues = Dommy::Rails::Lint.empty_links(MatchTarget.document(actual))
            @issues.empty?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have no empty links"
          end

          def failure_message
            "expected no empty links, found #{@issues.size} issues"
          end

          def failure_message_when_negated
            "expected empty links"
          end
        end

        class HaveNoNestedInteractiveElements
          def matches?(actual)
            @issues = Dommy::Rails::Lint.nested_interactive_elements(MatchTarget.document(actual))
            @issues.empty?
          end

          def does_not_match?(actual)
            !matches?(actual)
          end

          def description
            "have no nested interactive elements"
          end

          def failure_message
            "expected no nested interactive elements, found #{@issues.size} issues"
          end

          def failure_message_when_negated
            "expected nested interactive elements"
          end
        end

        class HaveHtmlLink
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

          def does_not_match?(mail)
            !matches?(mail)
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
          def initialize(text)
            @text = text
          end

          def matches?(mail)
            @document = Dommy::Rails::MailPart.html_document(mail)
            return false unless @document

            @actual = Dommy::Internal::DomMatching.text_of(@document)
            Dommy::Internal::DomMatching.text_matches?(@actual, @text)
          end

          def does_not_match?(mail)
            !matches?(mail)
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
          def initialize(text)
            @text = text
          end

          def matches?(mail)
            @actual = Dommy::Rails::MailPart.plain_body(mail).to_s
            Dommy::Internal::DomMatching.text_matches?(@actual, @text)
          end

          def does_not_match?(mail)
            !matches?(mail)
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
