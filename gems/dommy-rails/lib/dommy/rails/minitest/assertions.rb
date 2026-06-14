module Dommy
  module Rails
    module Minitest
      module Assertions
        def assert_dom_has_css(scope, selector, text: nil, count: nil, msg: nil)
          assert_dom_contains(scope, selector, text: text, count: count, msg: msg)
        end

        def refute_dom_has_css(scope, selector, text: nil, count: nil, msg: nil)
          refute_dom_contains(scope, selector, text: text, count: count, msg: msg)
        end

        def assert_dom_has_text(scope, text, msg: nil)
          assert_dom_contains_text(scope, text, msg: msg)
        end

        def refute_dom_has_text(scope, text, msg: nil)
          refute_dom_contains_text(scope, text, msg: msg)
        end

        def assert_dom_has_xpath(actual, expression, text: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.xpath_matches(dom_document_for(actual), expression, text: text)
          msg ||= "expected to contain XPath #{expression.inspect}#{text ? " with text #{text.inspect}" : ""}, found #{matched.size}"
          assert(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def refute_dom_has_xpath(actual, expression, text: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.xpath_matches(dom_document_for(actual), expression, text: text)
          msg ||= "expected NOT to contain XPath #{expression.inspect}#{text ? " with text #{text.inspect}" : ""}, found #{matched.size}"
          refute(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def assert_dom_has_title(actual, expected, msg: nil)
          matched = Dommy::Rails::PageInspector.title_matches?(dom_document_for(actual), expected)
          msg ||= "expected document title to match #{expected.inspect}"
          assert(matched, msg)
        end

        def refute_dom_has_title(actual, expected, msg: nil)
          matched = Dommy::Rails::PageInspector.title_matches?(dom_document_for(actual), expected)
          msg ||= "expected document title NOT to match #{expected.inspect}"
          refute(matched, msg)
        end

        # Assert the subject's ARIA snapshot matches `expected` (Playwright-style
        # subset; names may be /regex/).
        def assert_aria_snapshot(expected, actual, msg: nil)
          snapshot = dom_document_for(actual).aria_snapshot
          msg ||= "expected aria snapshot to match:\n#{expected}\ngot:\n#{snapshot}"
          assert(Dommy::Rails::AriaSnapshotMatching.matches?(snapshot, expected), msg)
        end

        def assert_dom_has_meta(actual, name: nil, property: nil, content: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.meta_matches?(dom_document_for(actual), name: name, property: property, content: content)
          msg ||= "expected to find meta #{meta_desc(name: name, property: property, content: content)}"
          assert(matched, msg)
        end

        def refute_dom_has_meta(actual, name: nil, property: nil, content: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.meta_matches?(dom_document_for(actual), name: name, property: property, content: content)
          msg ||= "expected NOT to find meta #{meta_desc(name: name, property: property, content: content)}"
          refute(matched, msg)
        end

        def assert_dom_has_csrf_meta_tags(actual, msg: nil)
          matched = Dommy::Rails::PageInspector.csrf_meta_tags?(dom_document_for(actual))
          msg ||= "expected to find Rails CSRF meta tags"
          assert(matched, msg)
        end

        def assert_dom_has_authenticity_token(actual, msg: nil)
          matched = Dommy::Rails::PageInspector.authenticity_token?(dom_document_for(actual))
          msg ||= "expected to find Rails authenticity token field"
          assert(matched, msg)
        end

        def assert_dom_has_link(actual, text = nil, href: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.links(dom_document_for(actual), text: text, href: href)
          msg ||= "expected to contain link#{text ? " with text #{text.inspect}" : ""}#{href ? " with href #{href.inspect}" : ""}, found #{matched.size}"
          assert(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def refute_dom_has_link(actual, text = nil, href: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.links(dom_document_for(actual), text: text, href: href)
          msg ||= "expected NOT to contain link#{text ? " with text #{text.inspect}" : ""}#{href ? " with href #{href.inspect}" : ""}, found #{matched.size}"
          refute(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def assert_dom_has_turbo_frame(actual, id = nil, text: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.turbo_frames(dom_document_for(actual), id, text: text)
          msg ||= "expected to contain turbo-frame#{id ? " ##{id}" : ""}#{text ? " with text #{text.inspect}" : ""}, found #{matched.size}"
          assert(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
          yield matched.first if block_given? && matched.any?
        end

        def refute_dom_has_turbo_frame(actual, id = nil, text: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.turbo_frames(dom_document_for(actual), id, text: text)
          msg ||= "expected NOT to contain turbo-frame#{id ? " ##{id}" : ""}#{text ? " with text #{text.inspect}" : ""}, found #{matched.size}"
          refute(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def assert_dom_has_select(actual, name = nil, label: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.selects(dom_document_for(actual), name: name, label: label)
          msg ||= "expected to contain select#{name ? " with name #{name.inspect}" : ""}#{label ? " with label #{label.inspect}" : ""}, found #{matched.size}"
          assert(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def refute_dom_has_select(actual, name = nil, label: nil, count: nil, msg: nil)
          matched = Dommy::Rails::PageInspector.selects(dom_document_for(actual), name: name, label: label)
          msg ||= "expected NOT to contain select#{name ? " with name #{name.inspect}" : ""}#{label ? " with label #{label.inspect}" : ""}, found #{matched.size}"
          refute(Dommy::Internal::DomMatching.count_matches?(matched.size, count), msg)
        end

        def assert_dom_has_checked_field(actual, name = nil, msg: nil)
          matched = Dommy::Rails::PageInspector.checkable_fields(dom_document_for(actual), name: name, checked: true)
          msg ||= "expected to find checked field#{name ? " #{name.inspect}" : ""}"
          assert(matched.any?, msg)
        end

        def assert_dom_has_unchecked_field(actual, name = nil, msg: nil)
          matched = Dommy::Rails::PageInspector.checkable_fields(dom_document_for(actual), name: name, checked: false)
          msg ||= "expected to find unchecked field#{name ? " #{name.inspect}" : ""}"
          assert(matched.any?, msg)
        end

        def assert_dom_has_form(actual, action: nil, method: nil, model: nil, msg: nil)
          document = dom_document_for(actual)
          matched = Dommy::Rails::FormInspector.matches?(document, action: action, method: method, model: model)
          msg ||= "expected to find form matching #{form_desc(action: action, method: method, model: model)}"
          assert(matched, msg)
        end

        def refute_dom_has_form(actual, action: nil, method: nil, model: nil, msg: nil)
          document = dom_document_for(actual)
          matched = Dommy::Rails::FormInspector.matches?(document, action: action, method: method, model: model)
          msg ||= "expected NOT to find form matching #{form_desc(action: action, method: method, model: model)}"
          refute(matched, msg)
        end

        def assert_dom_has_turbo_stream(actual, action:, target:, msg: nil)
          stream = Dommy::Rails::TurboStream.find(dom_body_for(actual), action: action, target: target)
          msg ||= "expected to find turbo-stream action=#{action} target=#{target}"
          assert(stream, msg)
          yield Dommy::Rails::TurboStream.fragment_document(stream) if block_given? && stream
        end

        def refute_dom_has_turbo_stream(actual, action:, target:, msg: nil)
          matched = Dommy::Rails::TurboStream.matches?(dom_body_for(actual), action: action, target: target)
          msg ||= "expected NOT to find turbo-stream action=#{action} target=#{target}"
          refute(matched, msg)
        end

        def assert_dom_appends_turbo_stream(actual, target, msg: nil, &block)
          assert_dom_has_turbo_stream(actual, action: "append", target: target, msg: msg, &block)
        end

        def assert_dom_replaces_turbo_stream(actual, target, msg: nil, &block)
          assert_dom_has_turbo_stream(actual, action: "replace", target: target, msg: msg, &block)
        end

        def assert_dom_updates_turbo_stream(actual, target, msg: nil, &block)
          assert_dom_has_turbo_stream(actual, action: "update", target: target, msg: msg, &block)
        end

        def assert_dom_removes_turbo_stream(actual, target, msg: nil, &block)
          assert_dom_has_turbo_stream(actual, action: "remove", target: target, msg: msg, &block)
        end

        def assert_dom_has_stimulus_controller(actual, name, msg: nil)
          matched = Dommy::Rails::Stimulus.controller?(dom_document_for(actual), name)
          msg ||= "expected to find element with Stimulus controller '#{name}'"
          assert(matched, msg)
        end

        def refute_dom_has_stimulus_controller(actual, name, msg: nil)
          matched = Dommy::Rails::Stimulus.controller?(dom_document_for(actual), name)
          msg ||= "expected NOT to find element with Stimulus controller '#{name}'"
          refute(matched, msg)
        end

        def assert_dom_has_stimulus_action(actual, action, msg: nil)
          matched = Dommy::Rails::Stimulus.action?(dom_document_for(actual), action)
          msg ||= "expected to find element with Stimulus action '#{action}'"
          assert(matched, msg)
        end

        def refute_dom_has_stimulus_action(actual, action, msg: nil)
          matched = Dommy::Rails::Stimulus.action?(dom_document_for(actual), action)
          msg ||= "expected NOT to find element with Stimulus action '#{action}'"
          refute(matched, msg)
        end

        def assert_dom_has_stimulus_target(actual, controller, target, msg: nil)
          matched = Dommy::Rails::Stimulus.target?(dom_document_for(actual), controller, target)
          msg ||= "expected to find element with Stimulus target '#{controller}.#{target}'"
          assert(matched, msg)
        end

        def refute_dom_has_stimulus_target(actual, controller, target, msg: nil)
          matched = Dommy::Rails::Stimulus.target?(dom_document_for(actual), controller, target)
          msg ||= "expected NOT to find element with Stimulus target '#{controller}.#{target}'"
          refute(matched, msg)
        end

        def assert_dom_has_stimulus_value(actual, controller, key, value, msg: nil)
          matched = Dommy::Rails::Stimulus.value?(dom_document_for(actual), controller, key, value)
          msg ||= "expected to find element with Stimulus value '#{controller}.#{key}' = #{value.inspect}"
          assert(matched, msg)
        end

        def refute_dom_has_stimulus_value(actual, controller, key, value, msg: nil)
          matched = Dommy::Rails::Stimulus.value?(dom_document_for(actual), controller, key, value)
          msg ||= "expected NOT to find element with Stimulus value '#{controller}.#{key}' = #{value.inspect}"
          refute(matched, msg)
        end

        def assert_dom_no_duplicate_ids(actual, msg: nil)
          document = dom_document_for(actual)
          duplicates = Dommy::Rails::Lint.duplicate_ids(document)
          msg ||= "expected no duplicate IDs, found: #{duplicates.join(', ')}"
          assert(duplicates.empty?, msg)
        end

        def assert_dom_no_invalid_aria_references(actual, msg: nil)
          document = dom_document_for(actual)
          issues = Dommy::Rails::Lint.invalid_aria_references(document)
          msg ||= "expected no invalid ARIA references, found #{issues.size} issues"
          assert(issues.empty?, msg)
        end

        def assert_dom_no_missing_form_labels(actual, msg: nil)
          document = dom_document_for(actual)
          issues = Dommy::Rails::Lint.missing_form_labels(document)
          msg ||= "expected no missing form labels, found #{issues.size} issues"
          assert(issues.empty?, msg)
        end

        def assert_dom_no_empty_links(actual, msg: nil)
          issues = Dommy::Rails::Lint.empty_links(dom_document_for(actual))
          msg ||= "expected no empty links, found #{issues.size} issues"
          assert(issues.empty?, msg)
        end

        def assert_dom_no_nested_interactive_elements(actual, msg: nil)
          issues = Dommy::Rails::Lint.nested_interactive_elements(dom_document_for(actual))
          msg ||= "expected no nested interactive elements, found #{issues.size} issues"
          assert(issues.empty?, msg)
        end

        def assert_mail_has_html_link(mail, text = nil, href: nil, count: nil, msg: nil)
          document = Dommy::Rails::MailPart.html_document(mail)
          msg ||= "expected mail to have an HTML part"
          assert(document, msg)
          assert_dom_has_link(document, text, href: href, count: count, msg: msg)
        end

        def assert_mail_has_html_text(mail, text, msg: nil)
          document = Dommy::Rails::MailPart.html_document(mail)
          msg ||= "expected mail HTML to contain #{text.inspect}"
          assert(document, "expected mail to have an HTML part")
          assert_dom_has_text(document, text, msg: msg)
        end

        def assert_mail_has_plain_text(mail, text, msg: nil)
          body = Dommy::Rails::MailPart.plain_body(mail).to_s
          msg ||= "expected mail plain text to contain #{text.inspect}, got #{body.inspect}"
          assert(Dommy::Internal::DomMatching.text_matches?(body, text), msg)
        end

        private

        def dom_document_for(actual)
          Dommy::Rails::MatchTarget.document(actual)
        end

        def dom_body_for(actual)
          Dommy::Rails::MatchTarget.body(actual)
        end

        def form_desc(action:, method:, model:)
          parts = []
          parts << "action=#{action}" if action
          parts << "method=#{method}" if method
          parts << "model=#{model}" if model
          parts.empty? ? "any form" : parts.join(" ")
        end

        def meta_desc(name:, property:, content:)
          parts = []
          parts << "name=#{name}" if name
          parts << "property=#{property}" if property
          parts << "content=#{content}" if content
          parts.empty? ? "matching any criteria" : parts.join(" ")
        end
      end
    end
  end
end
