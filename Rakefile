# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib"
  t.libs << "test"
  t.test_files = FileList["test/test_*.rb", "test/wpt/test_*.rb", "test/internal/test_*.rb"]
  t.verbose = false
end

task default: :test
