# frozen_string_literal: true

source "https://rubygems.org"

# All gems in this monorepo are resolved from their local paths during
# development, so there is no need for `path:` overrides per gem.
gem "dommy", path: "gems/dommy"
gem "dommy-rack", path: "gems/dommy-rack"
gem "capybara-dommy", path: "gems/capybara-dommy"
gem "dommy-rails", path: "gems/dommy-rails"

# HTML parser backend (Lexbor-based). Published on RubyGems; for makiri
# development, uncomment the `path:` override to use a local sibling checkout.
gem "makiri", ">= 0.6.0"
# gem "makiri", path: "../makiri"

# Shared dev tooling.
gem "rake", "~> 13.0"
gem "irb"
gem "rbs"
gem "rails", ">= 7.1"

# dommy benchmarks.
gem "benchmark-ips"
gem "memory_profiler"

# Minitest suites (dommy, dommy-rack).
gem "minitest", "~> 5.16"

# RSpec suite plus the Capybara driver compliance harness (capybara-dommy).
gem "rspec"
gem "sinatra"
gem "launchy"
gem "puma"
