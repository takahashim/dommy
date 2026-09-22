# frozen_string_literal: true

require_relative "test_helper"

# Three small things the Chromium differential harness turned up.
class TestOracleFollowups < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<form id=f><input name=a value=1></form><input id=n type=number step=0.1 value=0.1>")
  end

  # --- new FormData(form) --------------------------------------------------

  def test_form_data_takes_a_form_element_or_nothing
    form = @win.document.get_element_by_id("f")
    assert_equal([["a", "1"]], Dommy::FormData.from_js([form]).entries.to_a)
    assert_empty(Dommy::FormData.from_js([]).entries.to_a)
    assert_empty(Dommy::FormData.from_js([Dommy::Bridge::UNDEFINED]).entries.to_a)
  end

  def test_form_data_rejects_null_and_a_non_form
    assert_raises(Dommy::Bridge::TypeError) { Dommy::FormData.from_js([nil]) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::FormData.from_js([{}]) }
    assert_raises(Dommy::Bridge::TypeError) { Dommy::FormData.from_js([@win.document.body]) }
  end

  # --- stepUp / stepDown ------------------------------------------------------

  def test_step_arithmetic_is_decimal
    input = @win.document.get_element_by_id("n")
    input.step_up
    input.step_up
    assert_equal("0.3", input.value)
    input.step_down(3)
    assert_equal("0", input.value)
    input.set_attribute("step", "0.3")
    input.value = "1.1"
    input.step_up
    assert_equal("1.4", input.value)
    input.set_attribute("min", "0")
    input.set_attribute("max", "1")
    input.value = "0.9"
    input.step_up
    assert_equal("0.9", input.value) # the next step is past the max, and the last aligned value is where it was
  end

  # --- number value sanitization -----------------------------------------------

  def test_number_value_keeps_only_a_valid_floating_point_number
    input = @win.document.get_element_by_id("n")
    {"1e+2" => "1e+2", "-1.5" => "-1.5", ".5" => ".5", "1." => "", "+1" => "", " 1" => "", "1 " => "",
     "1e" => "", "2e308" => "", "Infinity" => "", "abc" => ""}.each do |raw, expected|
      input.value = raw
      assert_equal(expected, input.value, raw.inspect)
    end
  end

  # --- void methods return undefined over the bridge ---------------------------

  def test_the_void_method_set_names_only_operations_without_a_return_value
    runtime = Dommy::Js::HostBridge::HOST_RUNTIME_JS
    names = runtime[/const VOID_METHODS = new Set\(\[(.*?)\]\);/m, 1].scan(/"([^"]+)"/).flatten
    assert_includes(names, "addEventListener")
    assert_includes(names, "setAttribute")
    %w[close abort cancel write toggle reportValidity checkValidity dispatchEvent].each do |name|
      refute_includes(names, name, "#{name} returns a value somewhere")
    end
  end
end
