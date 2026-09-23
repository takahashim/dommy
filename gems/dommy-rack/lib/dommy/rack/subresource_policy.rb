# frozen_string_literal: true

module Dommy
  module Rack
    # Cross-origin subresource loading policy for a Session (see Resources,
    # which is the only consumer). Same-origin subresources always load; a
    # cross-origin host loads only when explicitly allowed (an embedding
    # browser prompts and calls #allow), or when the session runs in `:open`
    # mode (browser parity — the network backend's SSRF guard is then the real
    # boundary; see Session#open_subresources?). An embedder-owned denylist
    # predicate (e.g. a tracker/ad blocklist) wins over every other rule and is
    # recorded separately (dropped, not blocked): it was never a candidate to
    # prompt about.
    class SubresourcePolicy
      # An embedder-supplied ->(host){bool} denylist consulted before any
      # subresource is fetched (even in `:open` mode).
      attr_accessor :host_blocker

      def initialize
        @allowlist = []
        @blocked_hosts = []
        @dropped_hosts = []
        @host_blocker = nil
      end

      def allow(host)
        host = host.to_s
        @allowlist << host unless host.empty? || @allowlist.include?(host)
        self
      end

      def allowed?(host) = @allowlist.include?(host.to_s)

      def blocked_by_denylist?(host)
        return false unless @host_blocker

        !!@host_blocker.call(host.to_s)
      end

      # Hosts the denylist dropped this page. Distinct from #blocked_hosts: a
      # dropped host was refused on purpose (a tracker the embedder never
      # wants), so the UI surfaces it but never offers to load it, whereas a
      # blocked host is a cross-origin candidate awaiting a choice.
      def dropped_hosts = @dropped_hosts.dup

      def reset_dropped_hosts
        @dropped_hosts.clear
        self
      end

      def record_dropped(host)
        host = host.to_s
        @dropped_hosts << host unless host.empty? || @dropped_hosts.include?(host)
      end

      # Cross-origin hosts whose subresources were declined since the last
      # reset, so a UI can offer to allow them.
      def blocked_hosts = @blocked_hosts.dup

      def reset_blocked_hosts
        @blocked_hosts.clear
        self
      end

      def record_blocked(host)
        host = host.to_s
        @blocked_hosts << host unless host.empty? || @blocked_hosts.include?(host)
      end
    end
  end
end
