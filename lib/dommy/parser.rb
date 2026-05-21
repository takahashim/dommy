# frozen_string_literal: true

require "nokogiri"

module Dommy
  # Thin wrapper around Nokogiri's HTML5 fragment parser. Pinned to
  # `max_errors: 0` for silent recovery on malformed HTML (matching
  # browser behavior).
  #
  # Known quirks: `<table>`-only fragments wrap children in an
  # implicit `<tbody>`; `<select>` reparents non-option children
  # outside itself.
  #
  # `owner_doc` is critical: when a node parsed via a detached
  # fragment gets `add_child`'d into a Document with a different
  # Nokogiri owner, libxml2 silently **copies** the node (new
  # object_id) instead of moving it. That breaks identity-dependent
  # caches (e.g. `Document#wrap_node` and any reconciler that keys
  # off node identity). Always pass the destination document.
  module Parser
    def self.fragment(html, owner_doc: nil)
      if owner_doc
        owner_doc.fragment(html.to_s)
      else
        Nokogiri::HTML5.fragment(html.to_s, max_errors: 0)
      end
    end
  end
end
