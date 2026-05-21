# frozen_string_literal: true

require_relative "lib/dommy/version"

Gem::Specification.new do |spec|
  spec.name = "dommy"
  spec.version = Dommy::VERSION
  spec.authors = ["takahashim"]
  spec.email = ["takahashimm@gmail.com"]

  spec.summary = "happy-dom-style DOM polyfill in pure Ruby"
  spec.description = <<~DESC
    A pure-Ruby DOM polyfill on top of Nokogiri::HTML5, a Ruby-side
    analogue to JavaScript DOM libraries like happy-dom and jsdom.
    It exposes browser-like DOM semantics — events, MutationObserver,
    Custom Elements, Shadow DOM, the File API (Blob / File / FormData /
    DataTransfer), URL, Promise, timers, and Storage — without spinning
    up a real browser.

    Aimed at testing Ruby code that emits or consumes HTML. Includes
    drop-in RSpec matchers and Minitest assertions.
  DESC
  spec.homepage = "https://github.com/takahashim/dommy"
  spec.required_ruby_version = ">= 3.0"
  spec.license = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency("nokogiri", "~> 1.15")

end
