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
      # backend's engine. In a quirks-mode document that engine matches an id
      # selector ASCII case-insensitively, as CSS asks, while getElementById
      # still compares case-sensitively: its answer is kept only when the id
      # is exactly `id`, and otherwise the exact one is looked for among the
      # rest it matches. CSS.escape cannot make a selector of U+0000, which
      # CSSOM's "serialize an identifier" turns into U+FFFD — an id holding it
      # is found by comparing the attribute itself.
      def element_by_id(bnode, id)
        return bnode.css("[id]").find { |n| n["id"] == id } if id.include?("\u0000")

        selector = "##{Dommy::CSSNamespace.escape(id)}"
        first = bnode.at_css(selector)
        return first if first.nil? || first["id"] == id

        bnode.css(selector).find { |n| n["id"] == id }
      end

      # The class tokens getElementsByClassName looks for in `names`.
      def class_tokens(names) = Infra.split_on_ascii_whitespace(names)

      # The backend elements under `bnode` whose class list contains every one
      # of `tokens`, compared directly: a token may hold anything but ASCII
      # whitespace (`1`, `a.b`, `a:b`, `[x]`, a quote, NUL). In a quirks-mode
      # document they compare ASCII case-insensitively. The backend's own class
      # selector narrows the candidates first (see #class_candidates).
      def elements_with_classes(bnode, tokens, quirks:)
        wanted = quirks ? tokens.map { |t| t.downcase(:ascii) } : tokens
        class_candidates(bnode, tokens, quirks).select do |n|
          classes = Infra.split_on_ascii_whitespace(n["class"])
          classes = classes.map { |c| c.downcase(:ascii) } if quirks
          wanted.all? { |t| classes.include?(t) }
        end
      end

      # A superset of the elements with every one of `tokens`: what the
      # backend's class selector, the tokens escaped with CSS.escape, matches —
      # natively, where the comparison above runs in Ruby. That selector
      # compares exactly in a no-quirks document and ASCII case-insensitively
      # in one the backend parsed in quirks mode. It cannot spell U+0000
      # (CSS.escape writes U+FFFD), and it does not fold case when the backend
      # holds the document in no-quirks mode while Dommy's is quirks; then
      # every element with a class is a candidate.
      def class_candidates(bnode, tokens, quirks)
        doc = bnode.document
        if tokens.any? { |t| t.include?("\u0000") } || (quirks && !Backend.quirks_mode?(doc))
          return bnode.css("[class]")
        end

        bnode.css(tokens.map { |t| ".#{Dommy::CSSNamespace.escape(t)}" }.join)
      end

      # The HTML elements under `bnode` whose `name` is `name`. Only elements
      # in the HTML namespace count: an SVG or MathML element with a `name`
      # attribute is not one getElementsByName finds.
      #
      # Spec: https://html.spec.whatwg.org/multipage/dom.html#dom-document-getelementsbyname
      def elements_named(bnode, name)
        bnode.css("[name]").select { |n| n["name"] == name && Backend.namespace_uri(n) == Namespaces::HTML }
      end

      private_class_method :class_candidates
    end
  end
end
