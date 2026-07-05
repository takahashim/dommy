# frozen_string_literal: true

require_relative "lib/dommy/version"

Gem::Specification.new do |spec|
  spec.name = "dommy"
  spec.version = Dommy::VERSION
  spec.authors = ["takahashim"]
  spec.email = ["takahashimm@gmail.com"]

  spec.summary = "happy-dom-style DOM polyfill in pure Ruby"
  spec.description = <<~DESC
    A pure Ruby DOM polyfill built on Makiri, inspired by happy-dom and jsdom. It gives Ruby tests a browser style DOM with events, MutationObserver, Custom Elements, Shadow DOM, the File API, timers, and Storage, without requiring a real browser.
  DESC
  spec.homepage = "https://github.com/takahashim/dommy"
  spec.required_ruby_version = ">= 3.2"
  spec.license = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage

  # Includes the JS bridge runtime bundles (lib/dommy/js/*.js) read at load by
  # Dommy::Js::HostBridge, not just Ruby sources.
  spec.files = Dir["lib/**/*.rb", "lib/**/*.js", "README.md"]
  spec.require_paths = ["lib"]

  # Default HTML parser backend.
  spec.add_dependency "makiri", ">= 0.6.0"
  # used for window.btoa / atob
  spec.add_dependency "base64"
end
