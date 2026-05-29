# frozen_string_literal: true

module Dommy
  # Thin wrapper around the backend's HTML5 fragment parser. Delegates
  # to `Dommy::Backend.fragment` so backends can supply their own
  # implementation.
  #
  # Known quirks (vary by backend):
  # - Nokogiri (libxml2): `<table>`-only fragments wrap children in
  #   an implicit `<tbody>`; `<select>` reparents non-option children.
  # - Nokolexbor (Lexbor): similar behavior, slightly different edge
  #   cases for malformed input.
  #
  # `owner_doc` is critical: when a node parsed via a detached
  # fragment gets `add_child`'d into a Document with a different
  # owner, libxml2 silently **copies** the node (new object_id)
  # instead of moving it. That breaks identity-dependent caches
  # (e.g. `Document#wrap_node` and any reconciler that keys off
  # node identity). Always pass the destination document.
  module Parser
    def self.fragment(html, owner_doc: nil)
      if owner_doc
        owner_doc.fragment(html.to_s)
      else
        Backend.fragment(html.to_s, owner_doc: nil)
      end
    end
  end
end
