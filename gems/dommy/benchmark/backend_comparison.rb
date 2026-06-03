# frozen_string_literal: true

require "benchmark/ips"
require_relative "../lib/dommy"

# Compare the Nokogiri (libxml2) and Makiri (Lexbor) backends across the
# operations Dommy leans on: parsing, the query methods, identity-cached
# wrapping, text extraction, and cloneNode.
#
#   bundle exec ruby benchmark/backend_comparison.rb

BACKENDS = %i[nokogiri makiri].freeze

# A non-trivial document: 400 articles so parse/query costs dominate the
# per-call overhead.
ARTICLES = 400
html = +"<html><body><div id='main' class='container'><section class='content'>"
ARTICLES.times do |i|
  cls = i.even? ? "post featured" : "post"
  html << <<~ARTICLE
    <article id="post-#{i}" class="#{cls}" data-author="author-#{i % 7}">
      <h2 class="title">Title #{i}</h2>
      <p class="body">Body text number #{i} with some words.</p>
      <a href="/post/#{i}">read more</a>
    </article>
  ARTICLE
end
html << "</section></div></body></html>"
puts "Document: #{ARTICLES} articles, #{html.bytesize} bytes\n\n"

def with_backend(backend)
  Dommy::Backend.use(backend)
  yield
end

# Pre-parse one document per backend for the query/clone benchmarks.
docs = BACKENDS.to_h { |b| [b, with_backend(b) { Dommy.parse(html) }.document] }

def compare(title, backends)
  puts "── #{title} ──"
  Benchmark.ips do |x|
    x.config(time: 3, warmup: 1)
    backends.each { |b| x.report(b) { with_backend(b) { yield(b) } } }
    x.compare!
  end
  puts
end

compare("parse (full document)", BACKENDS) do
  Dommy.parse(html)
end

{
  "querySelector #id"            => "#post-200",
  "querySelector .class"         => ".post",
  "querySelector descendant"     => "section.content article .title",
  "querySelector [attr=]"        => "[data-author='author-3']",
}.each do |label, sel|
  compare("#{label}  (#{sel})", BACKENDS) do |b|
    docs[b].query_selector(sel)
  end
end

compare("querySelectorAll .post", BACKENDS) do |b|
  docs[b].query_selector_all(".post")
end

compare("getElementById", BACKENDS) do |b|
  docs[b].get_element_by_id("post-300")
end

compare("cloneNode(deep) of #main", BACKENDS) do |b|
  docs[b].get_element_by_id("main").clone_node(true)
end
