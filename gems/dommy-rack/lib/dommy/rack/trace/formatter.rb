# frozen_string_literal: true

module Dommy
  module Rack
    class Trace
      # Renders a Trace's event stream as a readable, action-grouped timeline
      # for humans and failure messages. The machine-readable serialization is
      # NDJSON (see Trace::Ndjson / #to_ndjson).
      module Formatter
        # A readable, action-grouped timeline. Events belonging to an action
        # are indented under its `ACTION` line.
        class Text
          def initialize(events)
            @events = events
          end

          def render
            @events.map { |event| line(event) }.join("\n")
          end

          private

          def line(event)
            event.type == :action ? body(event) : "  #{body(event)}"
          end

          def body(event)
            data = event.data
            case event.type
            when :action then "ACTION #{event.name}#{label(data[:label])}"
            when :http then http(data)
            when :form then "FORM #{data[:method]} #{data[:path]} #{compact(data[:params])}"
            when :document then "DOC #{data[:url]} title=#{data[:title].inspect}"
            when :script then script(data)
            when :console then "CONSOLE [#{data[:level]}] #{data[:text]}"
            when :js_error then "JS_ERROR #{data[:message]}"
            when :dom then dom(data)
            else "#{event.type.to_s.upcase} #{compact(data)}"
            end
          end

          def http(data)
            line = "HTTP #{data[:method]} #{data[:path]}#{query(data[:query])} #{data[:status]}"
            line += " -> #{data[:location]}" if data[:location]
            line
          end

          def script(data)
            where = data[:inline] ? "(inline)" : data[:src]
            data[:ok] ? "SCRIPT #{where} ok" : "SCRIPT #{where} error: #{data[:error]}"
          end

          def dom(data)
            label = "DOM #{data[:op]} #{data[:target]}"
            label += " x#{data[:count]}" if data[:count] && data[:count] > 1
            label += " [#{data[:attr]}]" if data[:attr]
            label
          end

          def label(value) = value ? " #{value.inspect}" : ""
          def query(value) = value ? "?#{value}" : ""
          def compact(value) = value.nil? ? "" : value.inspect
        end
      end
    end
  end
end
