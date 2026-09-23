# frozen_string_literal: true

require_relative "test_helper"

# Dommy::Js::ErrorLog — the shared ledger of errors the page left unhandled.
# The history / pending split is what makes a host's strict mode survive a
# navigation, so most of these pin that down.
class TestJsErrorLog < Minitest::Test
  def setup
    @log = Dommy::Js::ErrorLog.new
  end

  def record(message)
    @log.record(RuntimeError.new(message))
  end

  # --- Recording and checkpoints ---

  def test_a_checkpoint_raises_on_what_was_recorded
    record("boom")
    error = assert_raises(Dommy::JsError) { @log.check! }

    assert_includes error.message, "boom"
    assert_equal ["boom"], error.causes.map(&:message)
  end

  def test_a_checkpoint_is_quiet_with_nothing_pending
    assert_nil @log.check!
  end

  def test_each_error_is_reported_at_most_once
    record("boom")
    assert_raises(Dommy::JsError) { @log.check! }

    assert_nil @log.check!, "the queue drained, so the second checkpoint is quiet"
  end

  def test_the_message_names_where_the_page_was
    record("boom")
    error = assert_raises(Dommy::JsError) { @log.check!(context: "http://example.test/page") }

    assert_includes error.message, "http://example.test/page"
  end

  def test_a_non_strict_log_records_without_raising
    log = Dommy::Js::ErrorLog.new(strict: false)
    log.record(RuntimeError.new("boom"))

    assert_nil log.check!
    assert_equal ["boom"], log.errors.map(&:message), "still readable as history"
  end

  # --- allow ---

  def test_allow_suppresses_the_failure_but_keeps_the_history
    @log.allow { record("expected") }

    assert_nil @log.check!
    assert_equal ["expected"], @log.errors.map(&:message)
  end

  def test_allow_drops_what_was_pending_before_it
    record("earlier")
    @log.allow { record("expected") }

    assert_nil @log.check!, "leaving the block acknowledges everything outstanding"
  end

  def test_allow_restores_strictness_even_when_the_block_raises
    assert_raises(ArgumentError) { @log.allow { raise ArgumentError } }
    record("after")

    assert_raises(Dommy::JsError) { @log.check! }
  end

  def test_allow_nests
    @log.allow do
      @log.allow { record("inner") }
      record("outer")
    end

    assert_nil @log.check!
  end

  # --- The history / pending split ---

  def test_clearing_the_history_does_not_swallow_a_pending_error
    record("from the page that is going away")
    @log.clear_history

    assert_empty @log.errors, "the console's scrollback belongs to the old document"
    error = assert_raises(Dommy::JsError) { @log.check! }
    assert_includes error.message, "from the page that is going away"
  end

  def test_an_error_recorded_after_clearing_still_fails
    record("first page")
    @log.check! rescue nil # rubocop:disable Style/RescueModifier
    @log.clear_history
    record("second page")

    error = assert_raises(Dommy::JsError) { @log.check! }
    assert_equal ["second page"], error.causes.map(&:message)
  end

  def test_pending_reads_back_in_order
    record("one")
    record("two")

    assert_equal %w[one two], @log.pending.map(&:message)
    assert @log.pending?
  end

  # --- Retraction ---

  def test_record_returns_a_distinct_id_per_entry
    first = record("one")
    second = record("two")

    refute_equal first, second, "ids identify an entry so a report can be taken back"
  end

  # HTML's `rejectionhandled`: a promise reported as unhandled, then given a
  # handler after all, is one the page recovered from.
  def test_retracting_a_report_stops_it_failing
    id = record("recovered")

    assert @log.retract(id)
    assert_nil @log.check!
  end

  def test_retracting_leaves_the_history_alone
    @log.retract(record("recovered"))

    assert_equal ["recovered"], @log.errors.map(&:message),
      "the console keeps the line it already printed"
  end

  def test_retracting_takes_only_the_named_report
    kept = record("still broken")
    @log.retract(record("recovered"))

    error = assert_raises(Dommy::JsError) { @log.check! }
    assert_equal ["still broken"], error.causes.map(&:message)
    refute_nil kept
  end

  def test_retracting_an_unknown_or_missing_id_is_harmless
    refute @log.retract(nil)
    refute @log.retract(-1)
  end

  def test_a_report_already_checked_cannot_be_retracted
    id = record("boom")
    assert_raises(Dommy::JsError) { @log.check! }

    refute @log.retract(id), "the checkpoint already reported it"
  end
end
