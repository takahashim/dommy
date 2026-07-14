# frozen_string_literal: true

module Dommy
  # Thin wrapper around the backend's HTML5 fragment parser. Delegates
  # to `Dommy::Backend.fragment` so backends can supply their own
  # implementation.
  #
  # Known quirks (vary by backend):
  # - Nokogiri (libxml2): `<table>`-only fragments wrap children in
  #   an implicit `<tbody>`; `<select>` reparents non-option children.
  # - Makiri (Lexbor): similar behavior, slightly different edge
  #   cases for malformed input.
  #
  # `owner_doc` is critical: when a node parsed via a detached
  # fragment gets `add_child`'d into a Document with a different
  # owner, libxml2 silently **copies** the node (new object_id)
  # instead of moving it. That breaks identity-dependent caches
  # (e.g. `Document#wrap_node` and any reconciler that keys off
  # node identity). Always pass the destination document.
  module Parser
    @fragment_generation = 0

    class << self
      # Monotonic count of fragment parses in this process. A backend MAY
      # recycle a GC'd transient node's identity (pointer) — the transient
      # nodes come from fragment parses — so NodeWrapperCache can skip its
      # per-hit liveness validation (a backend round trip) as long as this
      # counter hasn't moved since the cache was created: no fragment parse,
      # no recyclable identity. This is why every fragment parse must go
      # through here rather than calling the backend's `fragment` directly.
      attr_reader :fragment_generation
    end

    def self.fragment(html, owner_doc: nil)
      @fragment_generation += 1
      if owner_doc
        owner_doc.fragment(html.to_s)
      else
        Backend.fragment(html.to_s, owner_doc: nil)
      end
    end
  end
end
