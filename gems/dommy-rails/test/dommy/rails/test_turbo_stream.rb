require "test_helper"

class TestTurboStream < Minitest::Test
  def test_matches_turbo_stream
    body = '<turbo-stream action="append" target="comments"><template><div>Comment</div></template></turbo-stream>'
    assert Dommy::Rails::TurboStream.matches?(body, action: "append", target: "comments")
    refute Dommy::Rails::TurboStream.matches?(body, action: "replace", target: "comments")
  end

  def test_fragment_for
    body = '<turbo-stream action="append" target="comments"><template><div>Comment</div></template></turbo-stream>'
    fragment = Dommy::Rails::TurboStream.fragment_for(body, action: "append", target: "comments")
    assert_equal "<div>Comment</div>", fragment
  end
end
