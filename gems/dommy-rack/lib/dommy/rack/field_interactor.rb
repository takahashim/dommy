# frozen_string_literal: true

require "dommy"

module Dommy
  module Rack
    # The field interactor now lives in dommy core
    # (Dommy::Interaction::FieldInteractor), shared with the standalone Browser
    # (it also fires input/change events now). Aliased here for existing refs.
    FieldInteractor = Dommy::Interaction::FieldInteractor
  end
end
