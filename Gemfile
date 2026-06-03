# frozen_string_literal: true

source "https://rubygems.org"

# All gems in this monorepo are resolved from their local paths during
# development, so there is no need for `path:` overrides per gem.
gem "dommy", path: "gems/dommy"
gem "dommy-rack", path: "gems/dommy-rack"
gem "capybara-dommy", path: "gems/capybara-dommy"

# HTML parser backends. At least one is required; both are listed so the
# dommy test suite can verify each adapter.
gem "nokogiri"
gem "makiri", path: "../makiri"

# Shared dev tooling.
gem "rake", "~> 13.0"
gem "irb"
gem "rbs"

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
