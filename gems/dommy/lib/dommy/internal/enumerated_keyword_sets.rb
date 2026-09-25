# frozen_string_literal: true

module Dommy
  module Internal
    # Keyword/default bundles for `reflect_enumerated` (reflected_attributes.rb)
    # that HTML defines once but that several elements reflect the same way —
    # kept here instead of copy-pasted at each `reflect_enumerated` call site.
    # A single-element attribute (`th.scope`, `link.as`, `track.kind`, media's
    # `preload`) stays inline in its own class instead of joining this module.
    module EnumeratedKeywordSets
      # HTML §2.5.4 "CORS settings attributes" (img/link/video/audio
      # `crossOrigin`, a `DOMString?`): "No CORS" — the missing value default —
      # has no keyword of its own, so a missing attribute reads back null;
      # invalid and empty value default are both "anonymous".
      CROSS_ORIGIN = {
        keywords: %w[anonymous use-credentials], missing: nil,
        invalid: "anonymous", empty: "anonymous", nullable: true
      }.freeze

      # HTML §2.5.5 "referrer policy attributes" (img/iframe/link/script
      # `referrerPolicy`). Every referrer policy token, including the empty
      # string itself, IS a keyword — so the empty state has a canonical
      # keyword ("") rather than reaching it as a fallback.
      REFERRER_POLICY = {
        keywords: ["", "no-referrer", "no-referrer-when-downgrade", "origin",
                   "origin-when-cross-origin", "same-origin", "strict-origin",
                   "strict-origin-when-cross-origin", "unsafe-url"],
        missing: "", invalid: ""
      }.freeze

      # HTML §2.5.7 "lazy loading attributes" (img/iframe `loading`).
      LAZY_LOADING = { keywords: %w[lazy eager], missing: "eager", invalid: "eager" }.freeze

      # HTML's "attributes for form submission" (form-control-infrastructure.html):
      # `method`/`enctype` on <form> carry both a missing and an invalid value
      # default; the corresponding `formmethod`/`formenctype` on a submit
      # button carry only the invalid one — an absent one falls all the way to
      # no state (read back as ""), rather than to the form's own default.
      METHOD = { keywords: %w[get post dialog], missing: "get", invalid: "get" }.freeze
      SUBMIT_BUTTON_METHOD = { keywords: %w[get post dialog], missing: nil, invalid: "get" }.freeze

      ENCTYPE_KEYWORDS = %w[application/x-www-form-urlencoded multipart/form-data text/plain].freeze
      ENCTYPE = {
        keywords: ENCTYPE_KEYWORDS, missing: "application/x-www-form-urlencoded",
        invalid: "application/x-www-form-urlencoded"
      }.freeze
      SUBMIT_BUTTON_ENCTYPE = {
        keywords: ENCTYPE_KEYWORDS, missing: nil,
        invalid: "application/x-www-form-urlencoded"
      }.freeze
    end
  end
end
