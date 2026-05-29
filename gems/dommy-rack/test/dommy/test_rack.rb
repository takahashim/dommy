# frozen_string_literal: true

require "test_helper"

class Dommy::TestRack < Minitest::Test
  include RackTestHelper

  def test_that_it_has_a_version_number
    refute_nil ::Dommy::Rack::VERSION
  end

  def test_session_initializes_with_an_app
    session = Dommy::Rack::Session.new(app_for({}))
    assert_instance_of Dommy::Rack::Session, session
    assert_nil session.current_url
    assert_nil session.document
  end

  def test_session_accepts_configuration
    session = Dommy::Rack::Session.new(
      app_for({}),
      default_host: "http://test.example",
      max_redirects: 2
    )
    assert_equal "http://test.example", session.default_host
    assert_equal 2, session.max_redirects
  end
end
