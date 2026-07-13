require_relative "lib/dommy/rails/version"

Gem::Specification.new do |spec|
  spec.name = "dommy-rails"
  spec.version = Dommy::Rails::VERSION
  spec.authors = ["takahashim"]
  spec.email = ["takahashimm@gmail.com"]
  spec.summary = "Rails integration for Dommy DOM testing"
  spec.description = "Rails-specific matchers and assertions for Dommy, including form helper understanding, Turbo Stream support, Stimulus attribute checking, and HTML quality linting."
  spec.homepage = "https://github.com/takahashim/dommy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dommy", "~> 0.10.0"
end
