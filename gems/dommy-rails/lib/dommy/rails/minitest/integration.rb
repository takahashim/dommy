# frozen_string_literal: true

module Dommy
  module Rails
    module Minitest
      module Integration
        include Dommy::Rails::DomSource
        include Dommy::Minitest::Assertions
        include Dommy::Rails::Minitest::Assertions
      end
    end
  end
end
