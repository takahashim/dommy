# frozen_string_literal: true

require_relative "test_helper"

class TestIDNA < Minitest::Test
  I = Dommy::Internal::IDNA

  def test_to_ascii_passes_through_ascii_lowercased
    assert_equal("example.test", I.to_ascii("example.test"))
    assert_equal("example.test", I.to_ascii("EXAMPLE.test"))
    assert_equal("example.test", I.to_ascii("Example.Test"))
  end

  def test_to_ascii_encodes_idn_label
    assert_equal("xn--wgv71a.test", I.to_ascii("日本.test"))
  end

  def test_to_ascii_handles_all_unicode_labels
    assert_equal("xn--wgv71a.xn--wgv71a", I.to_ascii("日本.日本"))
  end

  def test_to_ascii_preserves_xn_prefixed_label
    assert_equal("xn--wgv71a.test", I.to_ascii("xn--wgv71a.test"))
  end

  def test_to_ascii_handles_subdomain_mix
    assert_equal("sub.xn--wgv71a.test", I.to_ascii("sub.日本.test"))
  end

  def test_to_unicode_decodes_idn_label
    assert_equal("日本.test", I.to_unicode("xn--wgv71a.test"))
  end

  def test_to_unicode_passes_through_ascii
    assert_equal("example.test", I.to_unicode("example.test"))
  end

  def test_to_unicode_mixed
    assert_equal("sub.日本.test", I.to_unicode("sub.xn--wgv71a.test"))
  end

  def test_roundtrip
    %w[
      日本.test
      bücher.example
      sub.日本.co.jp
      пример.рф
    ].each do |domain|
      assert_equal(domain, I.to_unicode(I.to_ascii(domain)))
    end
  end

  def test_empty_labels_preserved
    # Trailing dot is significant in DNS — preserve the empty label.
    assert_equal("example.test.", I.to_ascii("example.test."))
  end

  def test_nil_passthrough
    assert_nil(I.to_ascii(nil))
    assert_nil(I.to_unicode(nil))
  end

  # --- NFC normalization ------------------------------------------

  def test_nfc_normalizes_decomposed_input
    # `é` decomposed (e + U+0301) should produce the same encoding as
    # the precomposed form.
    precomposed = "café.test"
    decomposed = "café.test"
    assert_equal(I.to_ascii(precomposed), I.to_ascii(decomposed))
  end

  # --- Case folding -----------------------------------------------

  def test_case_folding_for_non_ascii
    # Encoded Punycode for `Bücher` and `bücher` should match after
    # case folding.
    assert_equal(I.to_ascii("bücher.example"), I.to_ascii("Bücher.example"))
  end

  # --- Hyphen constraints -----------------------------------------

  def test_leading_hyphen_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("-abc.test") }
  end

  def test_trailing_hyphen_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("abc-.test") }
  end

  def test_double_hyphen_at_positions_3_4_rejected
    # `ab--cd` has hyphens at positions 3 and 4 without the `xn--` ACE
    # prefix → invalid per RFC 5891.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("ab--cd.test") }
  end

  def test_xn_prefix_exempt_from_3_4_hyphen_rule
    # The very pattern that the rule reserves for the ACE prefix is
    # itself allowed.
    assert_equal("xn--wgv71a.test", I.to_ascii("xn--wgv71a.test"))
  end

  def test_internal_hyphens_allowed
    assert_equal("my-domain.test", I.to_ascii("my-domain.test"))
    assert_equal("a-b-c.test", I.to_ascii("a-b-c.test"))
  end

  # --- Length constraints -----------------------------------------

  def test_label_over_63_octets_rejected
    long_ascii = "a" * 64
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("#{long_ascii}.test") }
  end

  def test_label_exactly_63_octets_allowed
    long_ascii = "a" * 63
    assert_equal("#{long_ascii}.test", I.to_ascii("#{long_ascii}.test"))
  end

  def test_domain_over_253_octets_rejected
    # 252 'a's + ".test" = 257 octets — over the cap.
    big = ("a" * 62 + ".") * 4 + "test"
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii(big) }
  end

  # --- UTS #46 mapping table -------------------------------------

  def test_fullwidth_letters_mapped_to_ascii
    # U+FF21 (FULLWIDTH LATIN CAPITAL LETTER A) maps to "a".
    assert_equal("a.test", I.to_ascii("Ａ.test"))
  end

  def test_compatibility_form_mapped
    # Roman numeral nine (U+2168 Ⅸ) decomposes/maps to "ix".
    assert_equal("ix.test", I.to_ascii("Ⅸ.test"))
  end

  def test_sharp_s_kept_in_nontransitional
    # WHATWG URL uses Transitional_Processing=false, so `ß` stays as
    # `ß` (Punycode-encoded), it is NOT mapped to "ss".
    encoded = I.to_ascii("faß.test")
    # Decoded form should still contain ß, not "ss".
    assert_equal("faß", I.to_unicode(encoded.split(".").first))
  end

  def test_disallowed_codepoint_rejected
    # U+E000 (Private Use Area) is disallowed per UTS #46.
    pua = [0xE000].pack("U*")
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("a#{pua}.test") }
  end

  # --- Bidi rule (RFC 5893) --------------------------------------

  def test_pure_rtl_label_ok
    # Hebrew letters only — valid Bidi RTL label.
    encoded = I.to_ascii("עברית.test")
    assert(encoded.start_with?("xn--"))
  end

  def test_rtl_label_ending_with_en_ok
    # RTL label may end with European digit (EN).
    assert(I.to_ascii("עברית1.test").start_with?("xn--"))
  end

  def test_ltr_label_with_arabic_rejected
    # LTR-starting label cannot contain AL (Arabic letter) — rule 5.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("aب.test") }
  end

  def test_mixing_en_and_an_in_rtl_rejected
    # RFC 5893 rule 4: EN and AN cannot coexist in a Bidi label.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("ب1٢.test") }
  end

  # --- ContextJ (RFC 5892) ---------------------------------------

  def test_zwnj_without_context_rejected
    # U+200C in isolation between basic letters → invalid context.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("ab‌cd.test") }
  end

  def test_zwj_without_context_rejected
    # U+200D without preceding Virama → invalid.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("ab‍cd.test") }
  end

  def test_zwnj_after_virama_ok
    # Hindi `हिन्‌दी` — ZWNJ after Devanagari halant (U+094D, Virama).
    encoded = I.to_ascii("हिन्‌दी.test")
    assert(encoded.start_with?("xn--"))
  end

  # --- A-label / U-label validity (RFC 5891 §4.2) -----------------

  def test_malformed_xn_label_rejected
    # `xn--abc` decodes to private-use / disallowed bytes (not a valid
    # U-label). Must be rejected.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("xn--abc.test") }
  end

  def test_xn_label_with_disallowed_decoded_codepoint_rejected
    # Construct an A-label that decodes to a Private Use character
    # (U+E000, IDNA-disallowed).
    pua = [0xE000].pack("U*")
    encoded = "xn--#{Dommy::Internal::Punycode.encode(pua)}.test"
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii(encoded) }
  end

  def test_valid_xn_label_passes_roundtrip_check
    # Sanity: a legitimately produced A-label survives the round-trip
    # validation.
    assert_equal("xn--wgv71a.test", I.to_ascii("xn--wgv71a.test"))
  end

  def test_empty_intermediate_label_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("a..b") }
  end

  def test_leading_dot_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii(".a.b") }
  end

  def test_trailing_dot_allowed
    # `example.test.` is a fully-qualified DNS name; the trailing
    # empty label is OK.
    assert_equal("example.test.", I.to_ascii("example.test."))
  end

  # --- ContextO (RFC 5892 §4) -------------------------------------

  def test_middle_dot_between_l_allowed
    # Catalan `l·l` ligature — the only legitimate use of U+00B7.
    assert(I.to_ascii("paral·lel.test").start_with?("xn--"))
  end

  def test_middle_dot_outside_l_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("a·b.test") }
  end

  def test_greek_lower_numeral_sign_before_greek_allowed
    assert(I.to_ascii("͵αβγ.test").start_with?("xn--"))
  end

  def test_greek_lower_numeral_sign_before_non_greek_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("͵abc.test") }
  end

  def test_hebrew_geresh_after_hebrew_allowed
    assert(I.to_ascii("שלום׳.test").start_with?("xn--"))
  end

  def test_hebrew_geresh_after_non_hebrew_rejected
    # Forces an LTR-starting label so we hit ContextO, not Bidi.
    geresh = [0x05F3].pack("U*")
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("abc#{geresh}.test") }
  end

  def test_hebrew_gershayim_after_hebrew_allowed
    assert(I.to_ascii("שלום״.test").start_with?("xn--"))
  end

  def test_katakana_middle_dot_with_japanese_allowed
    assert(I.to_ascii("カタカナ・テスト.test").start_with?("xn--"))
  end

  def test_katakana_middle_dot_without_japanese_rejected
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("a・b.test") }
  end

  def test_arabic_indic_digits_alone_have_no_contexto_issue
    # Pure ARABIC-INDIC digits trigger a Bidi error (label starts
    # with AN), not a ContextO error — different rule, same outcome.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("١٢٣.test") }
  end

  def test_mixed_arabic_indic_digit_kinds_rejected
    # `١` (Arabic-Indic 1) + `۱` (Extended Arabic-Indic 1) — §4.6/§4.7.
    assert_raises(Dommy::Internal::IDNA::Error) { I.to_ascii("١۱.test") }
  end
end
