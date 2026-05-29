# frozen_string_literal: true

# Aggregate Rake tasks for the Dommy monorepo. Each gem keeps its own Rakefile
# (and default task); this file just fans out to them.
GEMS = %w[dommy dommy-rack capybara-dommy].freeze

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

task default: :test
