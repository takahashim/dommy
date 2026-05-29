# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/dommy"

# Benchmark query selector performance

html = <<~HTML
  <html>
    <body>
      <div id="main" class="container">
        <section class="content">
          <article id="post-1" class="post featured">
            <h1>Title</h1>
            <p>Content</p>
          </article>
          <article id="post-2" class="post">
            <h1>Another</h1>
            <p>More content</p>
          </article>
          <article id="post-3" class="post">
            <h1>Third</h1>
            <p>Even more</p>
          </article>
        </section>
        <aside class="sidebar">
          <nav>
            <a href="#">Link 1</a>
            <a href="#">Link 2</a>
            <a href="#">Link 3</a>
          </nav>
        </aside>
      </div>
    </body>
  </html>
HTML

win = Dommy.parse(html)
doc = win.document

puts "=== Selector Performance Benchmark ==="
puts

# Simple selector
Benchmark.ips do |x|
  x.report("getElementById by ID selector") do
    doc.query_selector("#post-1")
  end

  x.report("querySelector by class") do
    doc.query_selector(".post")
  end

  x.report("querySelector by tag") do
    doc.query_selector("article")
  end

  x.report("querySelectorAll (3 results)") do
    doc.query_selector_all(".post")
  end

  x.report("querySelectorAll with descendant") do
    doc.query_selector_all(".content article")
  end

  x.report("querySelectorAll complex (descendant + class)") do
    doc.query_selector_all("div.container section.content article.post")
  end
end

puts
puts "=== Repeated Selector Calls (1000x) ==="
puts

Benchmark.ips do |x|
  x.report("querySelector #post-1 (1000x same)") do
    1000.times { doc.query_selector("#post-1") }
  end

  x.report("querySelectorAll .post (1000x same)") do
    1000.times { doc.query_selector_all(".post") }
  end
end

puts
puts "=== Memory Profile ==="
puts

require "memory_profiler"

report = MemoryProfiler.report do
  100.times do
    doc.query_selector("#post-1")
    doc.query_selector_all(".post")
    doc.query_selector_all(".content article")
  end
end

report.pretty_print(max_rows: 30)
