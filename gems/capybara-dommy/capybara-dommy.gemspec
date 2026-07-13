# frozen_string_literal: true

require_relative "lib/capybara/dommy/version"

Gem::Specification.new do |spec|
  spec.name = "capybara-dommy"
  spec.version = Capybara::Dommy::VERSION
  spec.authors = ["takahashim"]
  spec.email = ["takahashimm@gmail.com"]

  spec.summary = "A Dommy-backed Capybara driver"
  spec.description = <<~DESC
    capybara-dommy is a Capybara driver backed by Dommy and dommy-rack. It drives
    Rack/Rails apps through the Capybara DSL without a real browser or JavaScript,
    keeping the page as a Dommy::Document. RackTest-like, with HTML-level visibility.
  DESC
  spec.homepage = "https://github.com/takahashim/dommy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/takahashim/dommy/tree/main/gems/capybara-dommy"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        (f == ".rspec") ||
        f.start_with?(*%w[bin/ Gemfile .gitignore spec/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "capybara", ">= 3.40"
  spec.add_dependency "dommy", "~> 0.10.0"
  spec.add_dependency "dommy-rack", "~> 0.10.0"
end
