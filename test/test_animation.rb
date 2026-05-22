# frozen_string_literal: true

require_relative "test_helper"

class TestAnimation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='box'></div>")
    @doc = @win.document
    @box = @doc.query_selector("#box")
  end

  # --- Element#animate ---------------------------------------------

  def test_animate_returns_animation
    anim = @box.animate([{"opacity" => 0}, {"opacity" => 1}], "duration" => 300)
    assert_kind_of(Dommy::Animation, anim)
    assert_kind_of(Dommy::KeyframeEffect, anim.effect)
    assert_same(@box, anim.effect.target)
  end

  def test_animate_starts_running
    anim = @box.animate([{"opacity" => 0}, {"opacity" => 1}], "duration" => 300)
    assert_equal("running", anim.play_state)
  end

  def test_animate_with_duration_only_as_number
    anim = @box.animate([{"opacity" => 0}], 500)
    assert_equal(500, anim.effect.duration_ms)
  end

  def test_get_animations_lists_active_animations
    @box.animate([{"x" => 0}], "duration" => 100)
    @box.animate([{"y" => 0}], "duration" => 200)
    assert_equal(2, @box.get_animations.length)
  end

  def test_get_animations_empty_before_any_animation
    assert_equal([], @box.get_animations)
  end

  # --- Animation lifecycle -----------------------------------------

  def test_pause_changes_play_state
    anim = @box.animate([{"opacity" => 0}], "duration" => 500)
    anim.pause
    assert_equal("paused", anim.play_state)
  end

  def test_finish_sets_play_state_and_current_time
    anim = @box.animate([{"opacity" => 0}], "duration" => 400)
    anim.finish
    assert_equal("finished", anim.play_state)
    assert_equal(400, anim.current_time)
  end

  def test_cancel_sets_play_state_to_idle
    anim = @box.animate([{"opacity" => 0}], "duration" => 500)
    anim.cancel
    assert_equal("idle", anim.play_state)
    assert_nil(anim.current_time)
  end

  def test_finish_event_fires
    anim = @box.animate([{"opacity" => 0}], "duration" => 500)
    fired = false
    anim.add_event_listener("finish", proc { fired = true })
    anim.finish
    assert(fired)
  end

  def test_cancel_event_fires
    anim = @box.animate([{"opacity" => 0}], "duration" => 500)
    fired = false
    anim.add_event_listener("cancel", proc { fired = true })
    anim.cancel
    assert(fired)
  end

  # --- Auto-finish via scheduler ----------------------------------

  def test_animation_finishes_when_scheduler_advances
    anim = @box.animate([{"opacity" => 0}], "duration" => 250)
    assert_equal("running", anim.play_state)

    @win.scheduler.advance_time(250)
    assert_equal("finished", anim.play_state)
  end

  def test_animation_does_not_finish_when_paused_before_timer
    anim = @box.animate([{"opacity" => 0}], "duration" => 250)
    anim.pause
    @win.scheduler.advance_time(500)
    assert_equal("paused", anim.play_state)
  end

  # --- Promises ---------------------------------------------------

  def test_finished_promise_resolves_on_finish
    anim = @box.animate([{"opacity" => 0}], "duration" => 100)
    anim.finish
    result = anim.finished.await
    assert_same(anim, result)
  end

  def test_finished_promise_resolves_via_scheduler
    anim = @box.animate([{"opacity" => 0}], "duration" => 200)
    @win.scheduler.advance_time(200)
    assert_same(anim, anim.finished.await)
  end

  def test_ready_promise_resolves_immediately
    anim = @box.animate([{"opacity" => 0}], "duration" => 100)
    assert_same(anim, anim.ready.await)
  end

  def test_finished_promise_rejects_on_cancel
    anim = @box.animate([{"opacity" => 0}], "duration" => 100)
    anim.cancel
    assert_raises(RuntimeError) { anim.finished.await }
  end

  # --- JS bridge --------------------------------------------------

  def test_js_bridge_play_pause_finish
    anim = @box.animate([{"opacity" => 0}], "duration" => 200)
    anim.__js_call__("pause", [])
    assert_equal("paused", anim.__js_get__("playState"))
    anim.__js_call__("finish", [])
    assert_equal("finished", anim.__js_get__("playState"))
  end

  def test_window_exposes_animation_constructor
    ctor = @win.__js_get__("Animation")
    eff = Dommy::KeyframeEffect.new(@box, [{"x" => 0}], "duration" => 100)
    a = ctor.__js_new__([eff])
    assert_kind_of(Dommy::Animation, a)
    assert_same(eff, a.effect)
  end

  def test_window_exposes_keyframe_effect_constructor
    ctor = @win.__js_get__("KeyframeEffect")
    eff = ctor.__js_new__([@box, [{"opacity" => 0}], 100])
    assert_kind_of(Dommy::KeyframeEffect, eff)
    assert_equal(100, eff.duration_ms)
  end
end
