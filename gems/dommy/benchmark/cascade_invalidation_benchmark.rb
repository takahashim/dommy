# frozen_string_literal: true

# Measures what a mutate-then-read loop pays for cascade invalidation
# (RuleIndex rebuild + computed-style recompute). The epoch split (perf
# roadmap D1b) keeps the cascade caches warm across style-neutral mutations;
# this is the before/after evidence and the regression guard.
#
#   bundle exec ruby benchmark/cascade_invalidation_benchmark.rb   (from gems/dommy)

$LOAD_PATH.unshift File.expand_path("#{__dir__}/../lib")
require "dommy"

N = Integer(ENV.fetch("N", 500))
ELEMENTS = Integer(ENV.fetch("ELEMENTS", 300))
RULES = Integer(ENV.fetch("RULES", 100))

def realtime
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
end

def bench(label)
  yield # warm-up
  best = 3.times.map { realtime { yield } }.min
  puts format("%-58s %9.2f ms  (%8.2f us/op)", label, best * 1000, best * 1_000_000 / N)
  best
end

css = (1..RULES).map { |i|
  ".c#{i} { color: rgb(#{i % 256}, 0, 0); margin: #{i}px; } " \
  ".c#{i} .inner { padding: #{i}px; }"
}.join("\n")

body = (1..ELEMENTS).map { |i|
  "<div class=\"c#{(i % RULES) + 1}\" id=\"el#{i}\"><span class=\"inner\">item #{i}</span></div>"
}.join("\n")

html = "<!DOCTYPE html><html><head><style>#{css}</style></head><body>#{body}</body></html>"

window = Dommy.parse(html)
doc = window.document
el = doc.get_element_by_id("el1")
text = el.query_selector(".inner").first_child

cascade = Dommy::Internal::CSS::Cascade

puts "N=#{N} elements=#{ELEMENTS} rules=#{RULES} backend=#{Dommy::Backend.current.name.split('::').last}"

# Floor: computed style reads with a warm cache (no mutations at all).
bench("read computed_style, no mutation (cache floor)") do
  N.times { cascade.computed_style(el) }
end

# The RuleIndex rebuild alone (what one invalidation costs).
bench("RuleIndex.build alone") do
  N.times { Dommy::Internal::CSS::RuleIndex.build(doc) }
end

# The three mutation kinds D1b separates, each followed by one
# computed-style read (the Turbo-morph / assertion pattern).
bench("characterData edit + computed_style") do
  N.times { |i| text.data = "item #{i}"; cascade.computed_style(el) }
end

bench("data-* setAttribute + computed_style") do
  N.times { |i| el.set_attribute("data-n", i.to_s); cascade.computed_style(el) }
end

bench("class setAttribute + computed_style") do
  N.times { |i| el.set_attribute("class", "c#{(i % RULES) + 1}"); cascade.computed_style(el) }
end

# Same mutations followed by a querySelector (query-cache path, no cascade).
bench("characterData edit + querySelector") do
  N.times { |i| text.data = "item #{i}"; doc.query_selector(".c5 .inner") }
end

bench("data-* setAttribute + querySelector") do
  N.times { |i| el.set_attribute("data-n", i.to_s); doc.query_selector(".c5 .inner") }
end
