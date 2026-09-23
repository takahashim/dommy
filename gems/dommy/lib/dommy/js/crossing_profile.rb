# frozen_string_literal: true

module Dommy
  module Js
    # Counts trips across the JS<->Ruby boundary, grouped by ABI function and,
    # where the call names one, by interface/member — the measurement behind
    # "which property is this page reading a thousand times".
    #
    # Profiling is off unless DOMMY_JS_BRIDGE_PROFILE is set, and `.build`
    # answers with NullProfile then, so the bridge's hot paths call #count
    # unconditionally and pay one empty method call instead of a flag test at
    # every ABI entry point.
    class CrossingProfile
      def self.build(enabled: !ENV["DOMMY_JS_BRIDGE_PROFILE"].to_s.empty?)
        enabled ? new : NullProfile.new
      end

      def initialize
        @counts = new_counts
      end

      # Record one crossing of `abi_name`. `obj` and `member` are optional: with
      # them the crossing is also counted under an "Interface#member" label, so
      # the totals break down into what was actually being touched.
      def count(abi_name, obj = nil, member = nil)
        @counts[abi_name.to_s]["__total__"] += 1
        return nil unless member

        @counts[abi_name.to_s][label(obj, member)] += 1
        nil
      end

      # The counts, each ABI function's breakdown sorted by frequency and
      # optionally cut to the `limit` hottest labels.
      def snapshot(limit: nil)
        @counts.transform_values do |counts|
          sorted = counts.sort_by { |(_key, count)| -count }
          sorted = sorted.first(limit) if limit
          sorted.to_h
        end
      end

      def reset
        @counts = new_counts
        self
      end

      private

      def new_counts
        Hash.new { |hash, key| hash[key] = Hash.new(0) }
      end

      # "HTMLDivElement#className". Falls back to the Ruby class name when the
      # object has no derivable interface — a label is diagnostics, so it must
      # never be the thing that raises.
      def label(obj, member)
        return member.to_s unless obj

        iface = DomInterfaces.info(obj)["name"]
        "#{iface || obj.class.name}##{member}"
      rescue StandardError
        "#{obj.class.name}##{member}"
      end
    end

    # The profile a bridge holds when profiling is off: counts nothing, reports
    # nothing, and costs one call.
    class NullProfile
      def count(_abi_name, _obj = nil, _member = nil) = nil
      def snapshot(limit: nil) = {}
      def reset = self
    end
  end
end
