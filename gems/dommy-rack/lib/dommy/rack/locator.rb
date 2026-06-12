# frozen_string_literal: true

require "dommy"

module Dommy
  module Rack
    # The locator now lives in dommy core (Dommy::Interaction::Locator), shared
    # with the standalone Browser. Aliased here so existing references resolve.
    Locator = Dommy::Interaction::Locator
  end
end
