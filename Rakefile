# frozen_string_literal: true

# Aggregate Rake tasks for the Dommy monorepo. Each gem keeps its own Rakefile
# (and default task); this file just fans out to them.
GEMS = %w[dommy dommy-rack capybara-dommy dommy-rails].freeze

# All gems are versioned in lockstep; these hold the single VERSION constant each.
VERSION_FILES = {
  "dommy" => "gems/dommy/lib/dommy/version.rb",
  "dommy-rack" => "gems/dommy-rack/lib/dommy/rack/version.rb",
  "capybara-dommy" => "gems/capybara-dommy/lib/capybara/dommy/version.rb",
  "dommy-rails" => "gems/dommy-rails/lib/dommy/rails/version.rb",
}.freeze

GEMS.each do |name|
  desc "Run the #{name} test suite"
  task "test:#{name}" do
    Dir.chdir(File.join(__dir__, "gems", name)) do
      sh "bundle exec rake"
    end
  end
end

desc "Run every gem's test suite"
task test: GEMS.map { |name| "test:#{name}" }

desc "Print the current version of each gem"
task :version do
  VERSION_FILES.each do |name, file|
    version = File.read(File.join(__dir__, file))[/VERSION\s*=\s*"([^"]+)"/, 1]
    puts "#{name}: #{version}"
  end
end

namespace :version do
  desc "Set every gem to the same VERSION (e.g. rake version:bump VERSION=0.8.0)"
  task :bump do
    target = ENV["VERSION"] or abort "Usage: rake version:bump VERSION=x.y.z"
    abort "Invalid version: #{target}" unless target.match?(/\A\d+\.\d+\.\d+/)
    VERSION_FILES.each do |name, file|
      path = File.join(__dir__, file)
      content = File.read(path)
      updated = content.sub(/VERSION\s*=\s*"[^"]+"/, %(VERSION = "#{target}"))
      File.write(path, updated)
      puts "#{name} -> #{target}"
    end
  end
end

desc "Build and push every gem at the current version (run after version:bump)"
task release: :test do
  GEMS.each do |name|
    Dir.chdir(File.join(__dir__, "gems", name)) do
      sh "bundle exec rake release"
    end
  end
end

task default: :test
