# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestErrors < Minitest::Test
  # Navigation-specific errors descend from the Rack base error.
  NAVIGATION_ERROR_CLASSES = [
    Dommy::Rack::ElementNotClickableError,
    Dommy::Rack::UnsupportedURLError,
    Dommy::Rack::CrossOriginError,
    Dommy::Rack::TooManyRedirectsError,
    Dommy::Rack::UnsupportedContentTypeError,
    Dommy::Rack::InvalidFormError
  ].freeze

  # Element-finding / file errors are the shared interaction errors (the same
  # class whether driven by the Rack session or the standalone Browser);
  # Dommy::Rack::X remains a resolvable alias.
  SHARED_ERROR_CLASSES = [
    Dommy::Rack::ElementNotFoundError,
    Dommy::Rack::AmbiguousElementError,
    Dommy::Rack::FileNotFoundError
  ].freeze

  def test_navigation_errors_descend_from_base_error
    NAVIGATION_ERROR_CLASSES.each do |klass|
      assert klass < Dommy::Rack::Error, "#{klass} should descend from Dommy::Rack::Error"
    end
  end

  def test_shared_errors_are_interaction_errors
    SHARED_ERROR_CLASSES.each do |klass|
      assert klass < Dommy::Interaction::Error, "#{klass} should descend from Dommy::Interaction::Error"
    end
    assert_equal Dommy::Interaction::ElementNotFoundError, Dommy::Rack::ElementNotFoundError
  end

  def test_base_error_is_a_standard_error
    assert Dommy::Rack::Error < StandardError
    assert Dommy::Interaction::Error < StandardError
  end
end
