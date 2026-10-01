# frozen_string_literal: true

require_relative "infra"

module Dommy
  module Internal
    # getElementById, getElementsByClassName and getElementsByName: each
    # compares an attribute with a string, and none of them takes a CSS
    # selector. A value that would be special in one — a digit first, `.`, `:`,
    # a quote, a backslash, a newline, NUL — must still be found and never
    # raise, so these read the backend tree rather than compose a selector
    # string from their argument (getElementById uses the backend's id
    # selector as an index, and checks what it answers).
    module LiteralLookup
      module_function

      # The first backend element under `bnode` whose `id` is `id`, in tree
      # order. An id with selector-special characters (e.g. React's `useId`
      # values like `:rjm:`) is escaped into a valid id-selector ident for the
      # backend's engine (#selector_ident). In a quirks-mode document that
      # engine matches an id selector ASCII case-insensitively, as CSS asks,
      # while getElementById still compares case-sensitively: its answer is
      # kept only when the id is exactly `id`, and otherwise the exact one is
      # looked for among the rest it matches. No escape spells U+0000 (it
      # reads as U+FFFD), so an id holding it is found by comparing the
      # attribute itself. An element's id, like its classes and its name, is
      # the attribute of that name in no namespace (#attribute).
      def element_by_id(bnode, id)
        return bnode.css("[id]").find { |n| attribute(n, "id") == id } if id.include?("\u0000")

        selector = "##{selector_ident(id)}"
        first = bnode.at_css(selector)
        return first if first.nil? || attribute(first, "id") == id

        bnode.css(selector).find { |n| attribute(n, "id") == id }
      end

      # The class tokens getElementsByClassName looks for in `names`.
      def class_tokens(names) = Infra.split_on_ascii_whitespace(names)

      # The backend elements under `root`, a node of `document`, whose class
      # list contains every one of `tokens`, compared directly: a token may
      # hold anything but ASCII whitespace (`1`, `a.b`, `a:b`, `[x]`, a quote,
      # NUL). In a quirks-mode document they compare ASCII case-insensitively.
      # The backend's own class selector narrows the candidates first (see
      # #class_candidates).
      def elements_with_classes(document, root, tokens)
        quirks = document.quirks_mode?
        wanted = quirks ? tokens.map { |t| t.downcase(:ascii) } : tokens
        class_candidates(document, root, tokens).select do |n|
          classes = Infra.split_on_ascii_whitespace(attribute(n, "class"))
          classes = classes.map { |c| c.downcase(:ascii) } if quirks
          wanted.all? { |t| classes.include?(t) }
        end
      end

      # A superset of the elements with every one of `tokens`: what the
      # backend's class selector, the tokens escaped by #selector_ident,
      # matches — natively, where the comparison above runs in Ruby. That
      # selector compares exactly where the backend parsed a document in
      # no-quirks mode and ASCII case-insensitively where it parsed one in
      # quirks mode; Dommy takes the document's mode from that parse, so the
      # selector is never stricter than the comparison above — but a superset
      # must not rest on that, so a quirks-mode `document` over a backend that
      # does not fold scans instead. It cannot spell U+0000 (an escape of it
      # reads as U+FFFD); then too every element with a class is a candidate.
      def class_candidates(document, root, tokens)
        backend_folds = !document.quirks_mode? || Backend.quirks_mode?(document.backend_doc)
        return root.css("[class]") if !backend_folds || tokens.any? { |t| t.include?("\u0000") }

        root.css(tokens.map { |t| ".#{selector_ident(t)}" }.join)
      end

      # `value` as an ident a selector can carry whatever it holds: every code
      # point but an ASCII letter, an underscore, and (after the first) a
      # digit or U+002D written as a hex escape. CSS.escape is not enough —
      # it leaves a non-ASCII code point as it is, and css-syntax-3 counts
      # only some of them as ident code points (§4.2), so a class or an id of
      # U+00A0 or U+3000 would make an invalid selector.
      def selector_ident(value)
        value.each_char.with_index.map do |c, i|
          plain = i.zero? ? c.match?(/[A-Za-z_]/) : c.match?(/[A-Za-z0-9_-]/)
          plain ? c : "\\#{c.ord.to_s(16)} "
        end.join
      end

      # The HTML elements under `bnode` whose `name` is `name`. Only elements
      # in the HTML namespace count: an SVG or MathML element with a `name`
      # attribute is not one getElementsByName finds.
      #
      # Spec: https://html.spec.whatwg.org/multipage/dom.html#dom-document-getelementsbyname
      def elements_named(bnode, name)
        bnode.css("[name]").select { |n| Backend.namespace_uri(n) == Namespaces::HTML && attribute(n, "name") == name }
      end

      # The value of `node`'s attribute `name` in no namespace: an `id`,
      # `class` or `name` set with setAttributeNS("urn:x", …) is none of them.
      def attribute(node, name) = Backend.no_namespace_attribute_value(node, name)

      private_class_method :class_candidates, :selector_ident, :attribute
    end
  end
end
