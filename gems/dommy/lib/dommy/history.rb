# frozen_string_literal: true

module Dommy
  # `window.history` — one Document's view of its session history.
  #
  # The entries kept here are this Document's own same-document entries (the
  # ones pushState / replaceState and fragment navigations create), each a
  # session history entry with a URL, a serialized classic history API state and
  # a scroll restoration mode. Entries belonging to OTHER documents (the joint
  # session history of the tab) are the embedder's: a navigation delegate that
  # answers `history_length` supplies `history.length`, and a traversal that
  # leaves this document's entries is handed to the delegate's `traverse`.
  #
  # https://html.spec.whatwg.org/multipage/nav-history-apis.html#the-history-interface
  class History
    # `url` nil means "the document's URL": the first entry is created with the
    # Window, before an embedder has told the Location where the document lives,
    # so it reads the URL then and is pinned the first time history changes.
    Entry = Struct.new(:url, :state, :scroll_restoration)

    def initialize(window, location)
      @window = window
      @location = location
      @entries = [Entry.new(nil, nil, "auto")]
      @index = 0
      # The History object's state: the deserialized classic history API state of
      # the active entry. Restored (deserialized afresh) when the active entry
      # changes, so every read in between returns the same object.
      @state = nil
      @state_version = 0
    end

    # Host (embedding session) seam: called with (:push | :replace | :traverse,
    # url) after each change to this document's entries, so a session keeps its
    # joint history and current URL in step with the page's same-document
    # entries (Turbo Drive's pushState navigations, fragment navigations).
    attr_accessor :__internal_on_change__

    attr_reader :state

    def __js_get__(key)
      case key
      when "length"
        ensure_fully_active!
        length
      when "state"
        ensure_fully_active!
        @state
      when "__dommyStateVersion"
        # Which deserialization `state` currently holds: the JS side keeps one
        # object per version, so every read in between is the same object.
        ensure_fully_active!
        @state_version
      when "scrollRestoration"
        ensure_fully_active!
        active_entry.scroll_restoration
      else
        Bridge::ABSENT
      end
    end

    def __js_set__(key, value)
      case key
      when "scrollRestoration"
        ensure_fully_active!
        # The IDL enum: an assignment of anything else is ignored.
        v = value.to_s
        active_entry.scroll_restoration = v if %w[auto manual].include?(v)
      else
        return Bridge::UNHANDLED
      end

      nil
    end

    include Bridge::Methods
    js_methods %w[pushState replaceState back forward go]

    def __js_call__(method, args)
      case method
      when "pushState"
        push_or_replace_state(args[0], args[2], :push)
      when "replaceState"
        push_or_replace_state(args[0], args[2], :replace)
      when "back"
        delta_traverse(-1)
      when "forward"
        delta_traverse(1)
      when "go"
        delta_traverse(go_delta(args[0]))
      end
      nil
    end

    # Internal state pushState/replaceState read JS-side before serializing.
    def __internal_state__(name)
      @window.__internal_fully_active__? if name == "fully_active"
    end

    # `history.length`: the joint session history's size when the embedder keeps
    # one, otherwise this document's own entries.
    def length
      delegate = @window.navigation_delegate
      if delegate.respond_to?(:history_length)
        joint = delegate.history_length
        return joint if joint.is_a?(Integer) && joint.positive?
      end
      @entries.size
    end

    # The current entry index / traversal API for the host session, used to
    # mirror joint back/forward. go_to targets an absolute entry index (a
    # previously observed __internal_index__) and runs NOW — a Ruby-initiated
    # traversal has no script on the stack to return to first. Already there is
    # a no-op, so no spurious popstate fires.
    def __internal_index__ = @index

    def __internal_go_to__(index)
      traverse_to(index) unless index == @index
      nil
    end

    # The URLs of this document's entries, oldest first.
    def __internal_entry_urls__
      @entries.map { |entry| entry_url(entry) }
    end

    # A navigation that stays in this document (navigate to a fragment): add or
    # replace an entry for `url` with no classic history state, make it active,
    # then fire `popstate` now and `hashchange` from a task, as "update document
    # for history step application" does. Called by Location.
    def __internal_navigate_to_fragment__(url, replace:)
      old_url = active_url
      materialize_active_url
      add_entry(Entry.new(url, nil, active_entry.scroll_restoration), replace: replace)
      @location.__internal_set_url__(url, fire_hash: false)
      restore_state(nil)
      __internal_on_change__&.call(replace ? :replace : :push, @location.href)
      @window.__internal_fire_popstate__(nil)
      queue_hashchange(old_url, url)
      nil
    end

    private

    def active_entry = @entries[@index]

    # "Restore the history object state": deserialize the entry's serialized
    # state afresh.
    def restore_state(serialized)
      @state = Dommy.structured_deserialize(serialized)
      @state_version += 1
    end

    def entry_url(entry) = entry.url || @location.href

    def active_url = entry_url(active_entry)

    def materialize_active_url
      active_entry.url ||= @location.href
    end

    def add_entry(entry, replace:)
      if replace
        @entries[@index] = entry
      else
        @entries = @entries[0..@index] << entry
        @index = @entries.size - 1
      end
    end

    # "If this's relevant global object's associated Document is not fully
    # active, then throw a SecurityError" — the History of a removed frame is
    # still reachable from script, and refuses everything.
    def ensure_fully_active!
      return if @window.__internal_fully_active__?

      raise DOMException::SecurityError, "The document is not fully active"
    end

    # WebIDL `long` for go(delta): a missing / undefined / non-numeric argument is 0.
    def go_delta(value)
      return 0 if value.nil? || value.equal?(Bridge::UNDEFINED) || value == false

      return 1 if value == true

      n = value.is_a?(Numeric) ? value : Float(value.to_s.strip.then { |s| s.empty? ? "0" : s }, exception: false)
      return 0 if n.nil? || (n.is_a?(Float) && (n.nan? || n.infinite?))

      n = n.truncate % (1 << 32)
      n >= (1 << 31) ? n - (1 << 32) : n
    end

    # The shared history push/replace state steps.
    def push_or_replace_state(data, url, handling)
      ensure_fully_active!
      # StructuredSerializeForStorage comes first: a DataCloneError wins over a
      # bad URL.
      serialized = Dommy.structured_serialize(data)
      new_url = @location.href
      # A null (or omitted) URL, and — for historical reasons — the empty
      # string, keep the document's URL, fragment and all.
      unless url.nil? || url.equal?(Bridge::UNDEFINED) || url.to_s.empty?
        new_url = @window.__internal_parse_url__(url.to_s)
        if new_url.nil? || !can_have_url_rewritten?(@location.href, new_url)
          raise DOMException::SecurityError,
            "A history state object with URL '#{new_url || url}' cannot be created in a document with URL '#{@location.href}'."
        end
      end
      url_and_history_update(new_url, serialized, handling)
    end

    # A Document can have its URL rewritten to targetURL when scheme, username,
    # password, host and port all match; then http(s) may change anything else,
    # file: the query and fragment, and every other scheme only the fragment.
    def can_have_url_rewritten?(document_url, target_url)
      doc = Internal::UrlParser.parse(document_url)
      target = Internal::UrlParser.parse(target_url)
      return false unless %i[scheme username password host port].all? { |k| doc[k] == target[k] }
      return true if %w[http https].include?(target.scheme)
      return doc.path == target.path if target.scheme == "file"

      doc.path == target.path && doc.query == target.query
    rescue Internal::UrlParser::Failure
      false
    end

    # The URL and history update steps.
    def url_and_history_update(new_url, serialized, handling)
      materialize_active_url
      handling = :replace if @window.__internal_initial_about_blank__?
      add_entry(Entry.new(new_url, serialized, active_entry.scroll_restoration), replace: handling == :replace)
      # The history object's state is restored from the new entry: its
      # serialized state, deserialized afresh.
      restore_state(serialized)
      # Neither a navigation nor a traversal, so no hashchange.
      @location.__internal_set_url__(new_url, fire_hash: false)
      __internal_on_change__&.call(handling, @location.href)
    end

    # Delta traverse: go(0) reloads; any other delta is a traversal of the
    # session history, which runs from the traversal queue — the method returns
    # first, and popstate arrives in a later task.
    def delta_traverse(delta)
      ensure_fully_active!
      if delta.zero?
        @window.__internal_navigate__(url: @location.href, method: "GET", replace: true, source: :reload)
        return
      end

      @window.scheduler.set_timeout(proc { traverse_by(delta) }, 0)
    end

    # Run a traversal by `delta` now: within this document's entries it is a
    # same-document traversal; past either end it belongs to the joint session
    # history, which only the embedder knows.
    def traverse_by(delta)
      return unless @window.__internal_fully_active__?

      target = @index + delta
      if target.between?(0, @entries.size - 1)
        traverse_to(target)
      else
        delegate = @window.navigation_delegate
        delegate.traverse(delta) if delegate.respond_to?(:traverse)
      end
      nil
    end

    # Make the entry at `index` active: restore the URL and the history state,
    # tell the host, then fire popstate (and queue hashchange when the fragment
    # changed). The URL is restored BEFORE popstate, so a listener that reads
    # `location` (Turbo's restoration visit) sees the destination.
    def traverse_to(index)
      return unless index.between?(0, @entries.size - 1)

      old_url = active_url
      materialize_active_url
      @index = index
      new_url = active_url
      @location.__internal_set_url__(new_url, fire_hash: false)
      restore_state(active_entry.state)
      __internal_on_change__&.call(:traverse, new_url)
      @window.__internal_fire_popstate__(@state)
      queue_hashchange(old_url, new_url)
    end

    def queue_hashchange(old_url, new_url)
      return if fragment_of(old_url) == fragment_of(new_url)

      @window.scheduler.set_timeout(proc { @window.__internal_fire_hashchange__(old_url, new_url) }, 0)
    end

    def fragment_of(url)
      Internal::UrlParser.parse(url.to_s).fragment
    rescue Internal::UrlParser::Failure
      nil
    end
  end
end
