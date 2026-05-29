# frozen_string_literal: true

require "capybara"
require "dommy"
require "dommy/rack"

require_relative "dommy/version"
require_relative "dommy/errors"
require_relative "dommy/configuration"
require_relative "dommy/text_extractor"
require_relative "dommy/node"
require_relative "dommy/driver"

module Capybara
  module Dommy
  end
end
