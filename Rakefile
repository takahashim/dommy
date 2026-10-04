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

# The gemspecs that require another gem of the monorepo, and which ones: each
# pins the lockstep version with `~> X.Y.0`, so a bump has to move them too.
INTERNAL_DEPENDENCIES = {
  "dommy-rack" => %w[dommy],
  "capybara-dommy" => %w[dommy dommy-rack],
  "dommy-rails" => %w[dommy],
}.freeze

def gem_version(name)
  File.read(File.join(__dir__, VERSION_FILES.fetch(name)))[/VERSION\s*=\s*"([^"]+)"/, 1]
end

def gemspec_path(name) = File.join(__dir__, "gems", name, "#{name}.gemspec")

# The lockstep requirement on a monorepo gem: `~> X.Y.0` for version X.Y.Z.
def internal_requirement(version) = "~> #{version.split(".")[0, 2].join(".")}.0"

namespace :version do
  desc "Set every gem to the same VERSION, and their requirements on each other (e.g. rake version:bump VERSION=0.16.0)"
  task :bump do
    target = ENV["VERSION"] or abort "Usage: rake version:bump VERSION=x.y.z"
    abort "Invalid version: #{target}" unless target.match?(/\A\d+\.\d+\.\d+/)
    VERSION_FILES.each do |name, file|
      path = File.join(__dir__, file)
      File.write(path, File.read(path).sub(/VERSION\s*=\s*"[^"]+"/, %(VERSION = "#{target}")))
      puts "#{name} -> #{target}"
    end
    INTERNAL_DEPENDENCIES.each do |name, deps|
      path = gemspec_path(name)
      content = File.read(path)
      deps.each do |dep|
        content = content.sub(/(add_dependency "#{dep}", )"[^"]+"/, %(\\1"#{internal_requirement(target)}"))
      end
      File.write(path, content)
      puts "#{name} requires #{deps.join(", ")} #{internal_requirement(target)}"
    end
  end

  desc "Check every gem is at one version, which TAG (vX.Y.Z) names if given, and requires the others at it"
  task :check do
    versions = VERSION_FILES.keys.to_h { |name| [name, gem_version(name)] }
    errors = []
    errors << "versions differ: #{versions}" if versions.values.uniq.size > 1
    version = versions.fetch("dommy")
    if (tag = ENV["TAG"]) && tag != "v#{version}"
      errors << "tag #{tag} does not name the gems' version #{version}"
    end
    INTERNAL_DEPENDENCIES.each do |name, deps|
      content = File.read(gemspec_path(name))
      deps.each do |dep|
        found = content[/add_dependency "#{dep}", "([^"]+)"/, 1]
        errors << "#{name} requires #{dep} #{found.inspect}, not #{internal_requirement(version).inspect}" unless found == internal_requirement(version)
      end
    end
    abort errors.join("\n") unless errors.empty?
    puts "All gems at #{version}, requiring each other #{internal_requirement(version)}"
  end
end

# A release is a tag: pushing vX.Y.Z hands the test run, the build, the GitHub
# Release and the approval-gated RubyGems publish to CI
# (.github/workflows/release.yml). Nothing is pushed to RubyGems from here.
desc "Tag the gems' version and push the tag; CI tests, builds, releases and publishes"
task release: "version:check" do
  version = gem_version("dommy")
  tag = "v#{version}"
  abort "Uncommitted changes; commit or stash them first" unless `git status --porcelain --untracked-files=no`.strip.empty?
  abort "Not on main" unless `git rev-parse --abbrev-ref HEAD`.strip == "main"
  abort "Tag #{tag} already exists" if system("git", "rev-parse", "-q", "--verify", "refs/tags/#{tag}", out: File::NULL)
  abort "CHANGELOG has no section for #{version}" unless File.read(File.join(__dir__, "gems/dommy/CHANGELOG.md")).match?(/^## #{Regexp.escape(version)}\b/)

  sh "git", "tag", "-a", tag, "-m", "Version #{version}"
  sh "git", "push", "origin", tag
  puts <<~MSG

    Pushed #{tag}. GitHub Actions (release.yml) will now:
      1. check the versions and run every gem's tests,
      2. build the four gems and attach them to the GitHub Release, then
      3. publish them to RubyGems via OIDC - after the `rubygems` environment approval.
  MSG
end

task default: :test
