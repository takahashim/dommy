# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy::TextExtractor do
  # A driver gives the extractor its visibility policy + an element to read.
  def extract(html, css, **options)
    driver = driver_for(html, **options)
    element = driver.find_css(css).first.native
    [Capybara::Dommy::TextExtractor.new(driver), element]
  end

  it "includes hidden content in all_text" do
    extractor, el = extract("<div id='x'>A<span hidden>B</span>C</div>", "#x")
    expect(extractor.all_text(el)).to eq("ABC")
  end

  it "excludes hidden subtrees from visible_text" do
    extractor, el = extract("<div id='x'>A<span hidden>B</span>C</div>", "#x")
    expect(extractor.visible_text(el)).to eq("AC")
  end

  it "inserts a break between blocks in visible_text" do
    extractor, el = extract("<div id='x'><div>a</div><div>b</div></div>", "#x")
    expect(extractor.visible_text(el)).to eq("a\nb")
  end

  it "includes everything in :all visibility mode" do
    extractor, el = extract("<div id='x'>A<span hidden>B</span></div>", "#x", visibility: :all)
    expect(extractor.visible_text(el)).to eq("AB")
  end
end
