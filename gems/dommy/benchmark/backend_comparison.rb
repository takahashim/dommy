# frozen_string_literal: true

require "benchmark"
require_relative "../lib/dommy"

# Compare backends: Nokogiri vs Nokolexbor

html = <<~HTML
  <html>
    <body>
      <div id="main" class="container">
        <section class="content">
          <article id="post-1" class="post featured" data-author="alice">
            <h1>Title 1</h1>
            <p>Content 1</p>
          </article>
          <article id="post-2" class="post" data-author="bob">
            <h1>Title 2</h1>
            <p>Content 2</p>
          </article>
        </section>
      </div>
    </body>
  </html>
HTML

puts "=== Backend Comparison: Nokogiri vs Nokolexbor ==="
puts

# Parse + query benchmarks
def benchmark_backend(backend_name, html, selectors)
  Dommy::Backend.use(backend_name)

  win = Dommy.parse(html)
  doc = win.document

  results = {}
  selectors.each do |sel|
    bench = Benchmark.realtime do
      1000.times { doc.query_selector(sel) }
    end
    results[sel] = bench
  end
  results
end

selectors = [
  "#post-1",
  ".post",
  "article.post",
  "section.content article",
  "[data-author='alice']",
]

puts "\n--- Parse time (1000 iterations) ---"
[:nokogiri, :nokolexbor].each do |b|
  Dommy::Backend.use(b)
  time = Benchmark.realtime { 1000.times { Dommy.parse(html) } }
  puts "  #{b}: #{(time * 1000).round(1)}ms total (#{(time * 1000).round(3)}ms/parse)"
end

puts "\n--- Selector performance ---"
nokogiri_results = benchmark_backend(:nokogiri, html, selectors)
nokolexbor_results = benchmark_backend(:nokolexbor, html, selectors)

selectors.each do |sel|
  n = nokogiri_results[sel] * 1000
  l = nokolexbor_results[sel] * 1000
  speedup = (n / l).round(2)
  puts "  #{sel.ljust(35)}: Nokogiri=#{n.round(1)}ms  Nokolexbor=#{l.round(1)}ms  (#{speedup}× faster)"
end
