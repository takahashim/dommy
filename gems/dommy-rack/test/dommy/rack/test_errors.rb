# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestErrors < Minitest::Test
  ERROR_CLASSES = [
    Dommy::Rack::ElementNotFoundError,
    Dommy::Rack::ElementNotClickableError,
    Dommy::Rack::AmbiguousElementError,
    Dommy::Rack::UnsupportedURLError,
    Dommy::Rack::CrossOriginError,
    Dommy::Rack::TooManyRedirectsError,
    Dommy::Rack::UnsupportedContentTypeError,
    Dommy::Rack::InvalidFormError,
    Dommy::Rack::FileNotFoundError
  ].freeze

  def test_all_errors_descend_from_base_error
    ERROR_CLASSES.each do |klass|
      assert klass < Dommy::Rack::Error, "#{klass} should descend from Dommy::Rack::Error"
    end
  end

  def test_base_error_is_a_standard_error
    assert Dommy::Rack::Error < StandardError
  end
end
