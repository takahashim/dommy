# frozen_string_literal: true

require "json"

module Dommy
  module Rack
    class Trace
      # Serializes a Trace's event stream as NDJSON (trace-ndjson.md v2): one
      # compact JSON object per line, the authoritative order carried by `seq`,
      # the op-specific data flattened onto the line. This is the on-disk contract
      # the standalone trace viewer (dommy-trace-viewer) reads — neither side
      # depends on the other, only on this shape.
      #
      #   File.write("run.trace.ndjson", trace.to_ndjson(status: "failed"))
      #
      # An event's internal `type` is the line's `op`; `seq`/`t`/`action_seq` map
      # straight across. The one rename is `:dom`, whose mutation kind lives under
      # the reserved key `op` internally and is emitted as `kind`.
      module Ndjson
        VERSION = 2

        # The whole document: a trace_start line, one line per event, a trace_end
        # line. Returns a newline-terminated String (each line standalone JSON).
        # `artifacts` maps an artifact event's seq to its emission fields
        # (`{path:}` when externalized, `{content:, encoding:}` when inline).
        def self.document(events, level:, status:, artifacts: {}, wall_time: nil, metadata: nil, end_wall_ms: nil)
          lines = [start_line(level, wall_time, metadata)]
          events.each { |event| lines << event_line(event, artifacts) }
          lines << end_line(events, status, end_wall_ms)
          "#{lines.map { |hash| ::JSON.generate(hash) }.join("\n")}\n"
        end

        def self.start_line(level, wall_time, metadata)
          line = {seq: 0, op: "trace_start", t: nil, wall_ms: 0.0, version: VERSION, level: level.to_s}
          line[:wall_time] = wall_time if wall_time
          line[:metadata] = metadata if metadata
          line
        end

        def self.end_line(events, status, end_wall_ms)
          last = events.last
          {seq: (last&.seq || 0) + 1, op: "trace_end", t: last&.t,
           wall_ms: end_wall_ms || last&.wall_ms, status: status.to_s}
        end

        def self.event_line(event, artifacts = {})
          line = {seq: event.seq, op: op_for(event.type), t: event.t, wall_ms: event.wall_ms}
          line[:action] = event.action_seq if event.action_seq
          line.merge!(payload(event, artifacts))
          line
        end

        # The internal type maps straight to op, except `:artifact`, which the
        # viewer reads as `artifact_ref` (carrying either a path or content).
        def self.op_for(type) = type == :artifact ? "artifact_ref" : type.to_s

        # Op-specific fields. Most types pass their data through unchanged; an
        # action exposes verb/label, a dom mutation's `:op` becomes `kind`, and an
        # artifact merges in its emission fields (path or content) by seq.
        def self.payload(event, artifacts = {})
          data = event.data || {}
          case event.type
          when :action then {verb: data[:verb], label: data[:label], source: data[:source]}.compact
          when :dom then dom_payload(data)
          when :artifact then data.merge(artifacts[event.seq] || {})
          else data
          end
        end

        def self.dom_payload(data)
          out = data.dup
          out[:kind] = out.delete(:op) if out.key?(:op)
          out
        end
      end
    end
  end
end
