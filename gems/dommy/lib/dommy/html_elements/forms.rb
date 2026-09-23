# frozen_string_literal: true

# The form and its controls, split again: `<input>` and `<select>` are each
# large enough to read on their own — input carries twenty-odd types' worth of
# behaviour, select the option list it owns — and the rest are small beside them.
require_relative "forms/input"
require_relative "forms/select"
require_relative "forms/form"
