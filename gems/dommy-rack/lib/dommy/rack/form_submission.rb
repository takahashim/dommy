# frozen_string_literal: true

require "dommy"

module Dommy
  module Rack
    # The form-serialization logic now lives in dommy core
    # (Dommy::Interaction::FormSubmission). This thin subclass adapts the Rack
    # session's `config` object to core's explicit method-override keywords, so
    # existing `FormSubmission.new(form, submitter, config)` call sites and tests
    # keep working.
    class FormSubmission < Dommy::Interaction::FormSubmission
      def initialize(form, submitter, config)
        super(
          form, submitter,
          respect_method_override: config.respect_method_override,
          method_override_param: config.method_override_param
        )
      end
    end
  end
end
