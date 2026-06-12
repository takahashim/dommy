# frozen_string_literal: true

require "spec_helper"

RSpec.describe Capybara::Dommy::Node do
  def node(html, css, **options)
    driver_for(html, **options).find_css(css).first
  end

  it "treats class-based display:none as invisible (CSS cascade)" do
    n = node("<style>.hidden { display: none }</style><p id='x' class='hidden'>h</p>", "#x")
    expect(n).not_to be_visible
  end

  it "exposes a lowercase tag name" do
    expect(node("<input id='x'>", "#x").tag_name).to eq("input")
  end

  it "exposes attribute access" do
    n = node('<a id="x" href="/p" title="T">L</a>', "#x")
    expect(n["href"]).to eq("/p")
    expect(n[:title]).to eq("T")
    expect(n["data-missing"]).to be_nil
  end

  it "reads the value" do
    expect(node("<input id='x' value='hi'>", "#x").value).to eq("hi")
  end

  it "reports checked / selected / disabled / readonly state" do
    expect(node("<input id='x' type='checkbox' checked>", "#x")).to be_checked
    expect(node("<input id='x' type='checkbox'>", "#x")).not_to be_checked
    expect(node("<select><option id='x' selected>A</option></select>", "#x")).to be_selected
    expect(node("<input id='x' disabled>", "#x")).to be_disabled
    expect(node("<input id='x' readonly>", "#x")).to be_readonly
  end

  it "reports disabled state inherited from a fieldset" do
    expect(node("<fieldset disabled><input id='x'></fieldset>", "#x")).to be_disabled
  end

  it "returns an xpath for #path" do
    expect(node("<p>hi</p>", "p").path).to eq("/html/body/p")
  end

  it "computes visibility in html mode" do
    expect(node("<p id='x'>v</p>", "#x")).to be_visible
    expect(node("<p id='x' hidden>h</p>", "#x")).not_to be_visible
    expect(node("<input id='x' type='hidden'>", "#x")).not_to be_visible
    expect(node("<p id='x' style='display:none'>h</p>", "#x")).not_to be_visible
  end

  it "shows everything in :all visibility mode" do
    expect(node("<p id='x' hidden>h</p>", "#x", visibility: :all)).to be_visible
  end

  it "scopes find within the node" do
    outer = node('<div id="o"><span class="s">a</span><span class="s">b</span></div>', "#o")
    expect(outer.find_css(".s").size).to eq(2)
    expect(outer.find_xpath(".//span").size).to eq(2)
  end

  it "distinguishes all_text from visible_text" do
    n = node("<div id='x'>A<span hidden>B</span>C</div>", "#x")
    expect(n.all_text).to eq("ABC")
    expect(n.visible_text).to eq("AC")
  end

  it "inserts a break between block elements in visible_text" do
    n = node("<div id='x'><div>a</div><div>b</div></div>", "#x")
    expect(n.visible_text).to eq("a\nb")
  end

  it "keeps inline elements adjacent in visible_text" do
    n = node("<div id='x'><span>a</span><span>b</span></div>", "#x")
    expect(n.visible_text).to eq("ab")
  end

  it "raises on a stale node after navigation" do
    app = app_for(
      "GET /one" => html_response("<p id='x'>one</p>"),
      "GET /two" => html_response("<p id='y'>two</p>")
    )
    driver = Capybara::Dommy::Driver.new(app)
    driver.visit("/one")
    n = driver.find_css("#x").first
    expect(n.all_text).to eq("one")

    driver.visit("/two")
    expect { n.all_text }.to raise_error(Capybara::Dommy::StaleElementReferenceError)
  end
end
