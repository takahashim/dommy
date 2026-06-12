# frozen_string_literal: true

module Dommy
  module Rails
    module RSpec
      module Integration
        include Dommy::Rails::DomSource
        # Include order matters: Rails::RSpec::Matchers comes last so its
        # Rails-specific `have_link` (URL-normalizing `href:` matching)
        # deliberately overrides the CapyStyleMatchers version.
        include ::Dommy::RSpec::CapyStyleMatchers
        include Dommy::Rails::RSpec::Matchers
      end
    end
  end
end
