# frozen_string_literal: true

require "json"

module Dommy
  module Rack
    class Trace
      # Serializes a Trace's event stream as NDJSON (trace-ndjson.md v2): one
      # compact JSON object per line, the authoritative order carried by `seq`,
      # the op-specific data flattened onto the line. This is the on-disk contract
      # the standalone trace viewer (dommylizer) reads — neither side depends on
      # the other, only on this shape.
      #
      # An instance holds one document's context (level, the artifact emission
      # fields by seq, wall_time/metadata, end_wall_ms); #document renders the
      # whole stream for a given status:
      #
      #   File.write("run.trace.ndjson",
      #     Trace::Ndjson.new(events, level: :verbose, end_wall_ms: now).document(status: "failed"))
      #
      # An event's internal `type` is the line's `op`; `seq`/`t`/`action_seq` map
      # straight across. The one rename is `:dom`, whose mutation kind lives under
      # the reserved key `op` internally and is emitted as `kind`.
      class Ndjson
        VERSION = 2

        # `artifacts` maps an artifact event's seq to its emission fields
        # (`{path:}` when externalized, `{content:, encoding:}` when inline).
        def initialize(events, level:, artifacts: {}, wall_time: nil, metadata: nil, end_wall_ms: nil)
          @events = events
          @level = level
          @artifacts = artifacts
          @wall_time = wall_time
          @metadata = metadata
          @end_wall_ms = end_wall_ms
        end

        # The whole document: a trace_start line, one line per event, a trace_end
        # line. Returns a newline-terminated String (each line standalone JSON).
        def document(status:)
          lines = [start_line, *@events.map { |event| event_line(event) }, end_line(status)]
          "#{lines.map { |hash| ::JSON.generate(hash) }.join("\n")}\n"
        end

        # One event's line. Public so the type->op mapping can be unit-tested.
        def event_line(event)
          line = {seq: event.seq, op: op_for(event.type), t: event.t, wall_ms: event.wall_ms}
          line[:action] = event.action_seq if event.action_seq
          line.merge!(payload(event))
          line
        end

        private

        def start_line
          line = {seq: 0, op: "trace_start", t: nil, wall_ms: 0.0, version: VERSION, level: @level.to_s}
          line[:wall_time] = @wall_time if @wall_time
          line[:metadata] = @metadata if @metadata
          line
        end

        def end_line(status)
          last = @events.last
          {seq: (last&.seq || 0) + 1, op: "trace_end", t: last&.t,
           wall_ms: @end_wall_ms || last&.wall_ms, status: status.to_s}
        end

        # The internal type maps straight to op, except `:artifact`, which the
        # viewer reads as `artifact_ref` (carrying either a path or content).
        def op_for(type) = type == :artifact ? "artifact_ref" : type.to_s

        # Op-specific fields. Most types pass their data through unchanged; an
        # action exposes verb/label, a dom mutation's `:op` becomes `kind`, and an
        # artifact merges in its emission fields (path or content) by seq.
        def payload(event)
          data = event.data || {}
          case event.type
          when :action then {verb: data[:verb], label: data[:label], source: data[:source]}.compact
          when :dom then dom_payload(data)
          when :artifact then data.merge(@artifacts[event.seq] || {})
          else data
          end
        end

        def dom_payload(data)
          out = data.dup
          out[:kind] = out.delete(:op) if out.key?(:op)
          out
        end
      end
    end
  end
end
