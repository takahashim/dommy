# frozen_string_literal: true

# Generates THE contract trace: a fixed browsing scenario whose NDJSON output
# is committed as test/fixtures/contract.trace.ndjson here AND vendored by the
# standalone viewer (dommylizer) as its parse fixture — the two sides share no
# code, only this file format. Regenerate (after an intentional format change)
# with:
#
#   bundle exec ruby -Itest -r support/trace_contract -e 'TraceContract.write!'
#
# Timing fields (wall_ms / t / wall_time) are volatile; contract tests compare
# with TraceContract.normalize applied to both sides.
module TraceContract
  FIXTURE = File.expand_path("../fixtures/contract.trace.ndjson", __dir__)

  FORM_PAGE = <<~HTML
    <html><head><title>Form</title></head><body>
      <form method="post" action="/submit">
        <label for="title">Title</label>
        <input id="title" name="title" type="text">
        <button type="submit" name="commit">Create</button>
      </form>
    </body></html>
  HTML

  DONE_PAGE = "<html><head><title>Done</title></head><body><h1>Created</h1></body></html>"

  module_function

  def app
    routes = {
      "GET /form" => [200, {"Content-Type" => "text/html"}, [FORM_PAGE]],
      "POST /submit" => [302, {"Content-Type" => "text/html", "Location" => "/done"}, [""]],
      "GET /done" => [200, {"Content-Type" => "text/html"}, [DONE_PAGE]],
    }
    lambda do |env|
      req = ::Rack::Request.new(env)
      routes["#{req.request_method} #{req.path}"] ||
        [404, {"Content-Type" => "text/plain"}, ["Not Found"]]
    end
  end

  def generate
    session = Dommy::Rack::Session.new(app, trace: true)
    session.visit "/form"
    session.fill_in "Title", with: "Hello"
    session.click_button "Create"
    session.trace.record_error(
      message: 'expected to find text "Missing"',
      exception_class: "Minitest::Assertion",
      source: "spec/contract_spec.rb:12"
    )
    session.trace.to_ndjson(status: "failed")
  end

  def write!
    File.write(FIXTURE, generate)
    puts "wrote #{FIXTURE}"
  end

  # Strip the volatile fields so structure/content compare deterministically.
  def normalize(ndjson)
    ndjson.each_line.map do |line|
      parsed = JSON.parse(line)
      parsed.delete("wall_ms")
      parsed.delete("t")
      parsed.delete("wall_time")
      # An action's source is the generating call site — file:line shifts.
      parsed.delete("source")
      parsed
    end
  end
end
