# frozen_string_literal: true

module Dommy
  # Elements that host content from somewhere else.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  class HTMLIFrameElement < HTMLElement
    reflect_token_list sandbox: { supported: Internal::SupportedTokens::IFRAME_SANDBOX }
    reflect_enumerated loading: Internal::EnumeratedKeywordSets::LAZY_LOADING,
                       referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy")

    # HTML §4.8.5 / §7.3.1: an iframe in a document that has a browsing
    # context has a child navigable from the moment it is connected (its
    # post-connection steps), whose first document is the initial about:blank;
    # `contentDocument` is that navigable's active document. The navigable goes
    # away when the iframe is removed (its removing steps), so a disconnected
    # iframe — and one in a document without a browsing context — has none.
    #
    # A parser-inserted iframe gets its navigable when script boot replays the
    # parser's insertions (Document#__internal_process_parsed_iframes__), or on
    # first access for a document that is never booted.
    def content_document
      return @content_document if @content_document
      return nil unless __internal_can_have_child_navigable__?

      __internal_create_child_navigable__
      @content_document
    end

    # Whether this iframe is where a child navigable lives: connected, in a
    # document that has a browsing context.
    def __internal_can_have_child_navigable__?
      return false unless respond_to?(:is_connected?) && is_connected?

      view = owner_document&.default_view
      !view.nil? && view.navigable?
    end

    # "Create a new child navigable": a fresh browsing context whose document
    # is the initial about:blank, named after the `name` attribute.
    def __internal_create_child_navigable__
      return if @content_document

      @navigation_id = (@navigation_id || 0) + 1
      __internal_install_content_window__(__internal_initial_about_blank_window__, name: __internal_attribute_value__("name"))
      nil
    end

    # "Destroy a child navigable" (the iframe removing steps): the navigable
    # and its document go away without unload events; a navigation still in
    # flight is dropped. The Window survives for a script that holds it,
    # closed.
    def __internal_destroy_child_navigable__
      window = @content_document&.default_view
      @content_document = nil
      @navigation_id = (@navigation_id || 0) + 1
      @attributes_processed = false
      @lazy_load_resumption = nil
      window&.__internal_discard__
      nil
    end

    # The iframe post-connection steps: create the child navigable, then
    # process the iframe attributes as the initial insertion.
    def __internal_post_connection__
      return unless __internal_can_have_child_navigable__?

      __internal_create_child_navigable__
      @attributes_processed = true
      __internal_process_iframe_attributes__(initial_insertion: true)
    end

    # The parser inserted this iframe, and script boot is replaying that
    # insertion: its post-connection steps run unless they already have (an
    # embedder that read contentDocument first gave it a navigable, but did
    # not process its attributes).
    def __internal_parser_inserted__
      return if @attributes_processed

      __internal_post_connection__
    end

    # The iframe attribute change steps: with a child navigable, setting,
    # changing or removing `srcdoc` — or `src` while there is no `srcdoc` —
    # processes the iframe attributes again.
    def __internal_attribute_changed__(name, old_value, new_value, namespace)
      super
      return unless namespace.nil? && @content_document

      if name == "loading"
        # The `loading` attribute leaving the Lazy state runs the pending lazy
        # load resumption steps.
        __internal_resume_lazy_load__ unless new_value.to_s.casecmp?("lazy")
      elsif name == "srcdoc" || (name == "src" && __internal_attribute_value__("srcdoc").nil?)
        __internal_process_iframe_attributes__
      end
      nil
    end

    # "Process the iframe attributes".
    def __internal_process_iframe_attributes__(initial_insertion: false)
      @lazy_load_resumption = nil
      srcdoc = __internal_attribute_value__("srcdoc")
      unless srcdoc.nil?
        navigate = proc { __internal_navigate_content__("about:srcdoc", srcdoc: srcdoc.to_s, replace: initial_insertion) }
        return lazy_load(navigate) if __internal_will_lazy_load__?

        navigate.call
        return
      end

      url = __internal_shared_attribute_processing__(initial_insertion)
      return if url.nil?

      if initial_insertion && Internal::ChildNavigable.matches_about_blank?(url)
        __internal_run_iframe_load_event_steps__
        return
      end

      navigate = proc { __internal_navigate_content__(url, replace: initial_insertion) }
      return lazy_load(navigate) if __internal_will_lazy_load__?

      navigate.call
    end

    # "Will lazy load element steps": a `loading=lazy` iframe in a document
    # that runs scripts defers its navigation until it nears the viewport.
    def __internal_will_lazy_load__?
      return false unless __internal_attribute_value__("loading").to_s.casecmp?("lazy")

      view = owner_document&.default_view
      !view.nil? && view.navigable?
    end

    # Keep the rest of the navigation as the lazy load resumption steps.
    # Dommy has no layout to intersect with, so every lazy frame counts as
    # nearing the viewport once its document has loaded (which, as HTML
    # wants, it does not delay) — or at once when it already has.
    def lazy_load(navigate)
      @lazy_load_resumption = navigate
      owner_document.__internal_after_load__ { __internal_resume_lazy_load__(navigate) }
      nil
    end
    private :lazy_load

    # Run the lazy load resumption steps, when `steps` are still the ones
    # pending.
    def __internal_resume_lazy_load__(steps = @lazy_load_resumption)
      return nil unless steps && steps.equal?(@lazy_load_resumption)

      @lazy_load_resumption = nil
      steps.call
      nil
    end

    # "The shared attribute processing steps for iframe and frame elements":
    # the `src` URL (about:blank when absent, empty or unparsable), or nil when
    # it would load a document one of its ancestors already shows.
    def __internal_shared_attribute_processing__(initial_insertion)
      url = "about:blank"
      src = __internal_attribute_value__("src")
      if src && !src.empty?
        parsed = owner_document&.default_view&.__internal_parse_url__(src)
        url = parsed if parsed
      end
      return nil if __internal_ancestor_shows__?(url)

      # "about:blank?foo": the initial about:blank document takes that URL.
      if initial_insertion && Internal::ChildNavigable.matches_about_blank?(url)
        @content_document&.default_view&.location&.__internal_set_url__(url)
      end
      url
    end

    # Whether an inclusive ancestor navigable of this iframe's node navigable
    # shows a document whose URL equals `url`, fragments excluded.
    def __internal_ancestor_shows__?(url)
      target = Internal::ChildNavigable.without_fragment(url)
      window = owner_document&.default_view
      seen = []
      while window && !seen.include?(window)
        seen << window
        return true if Internal::ChildNavigable.without_fragment(window.location.href) == target

        window = window.frame_element&.owner_document&.default_view
      end
      false
    end

    # Navigate this iframe's child navigable to `url` (HTML "navigate an iframe
    # or frame"). Navigation is not synchronous: the document is made (or
    # fetched by the embedder) in a task, and only the latest navigation
    # requested completes. A navigation to a network URL goes to the parent
    # window's navigation delegate, when it answers `load_frame`; without one
    # the navigable keeps its document.
    #
    # `sync: true` performs it at once (an embedder that already decided when
    # to load the frame).
    def __internal_navigate_content__(url, srcdoc: nil, nav: {}, replace: false, sync: false)
      return nil unless @content_document

      # A navigation of the navigable drops a lazy load still pending.
      @lazy_load_resumption = nil
      id = @navigation_id = (@navigation_id || 0) + 1
      @pending_navigation = id
      perform = proc do
        next unless id == @navigation_id && @content_document

        @pending_navigation = nil
        window = __internal_child_document_for__(url, srcdoc, nav)
        next unless window && id == @navigation_id && @content_document

        __internal_install_content_window__(window)
        __internal_run_iframe_load_event_steps__
      end
      scheduler = owner_document&.__internal_scheduler__
      sync || scheduler.nil? ? perform.call : scheduler.set_timeout(perform, 0)
      nil
    end

    # Whether a navigation of the child navigable is queued and not yet
    # performed — it delays the load event of this element's document.
    def __internal_navigation_pending__?
      !@pending_navigation.nil? && @pending_navigation == @navigation_id && !@content_document.nil?
    end

    # The document a navigation of the child navigable to `url` produces, as
    # its Window, or nil when there is none to be had.
    def __internal_child_document_for__(url, srcdoc, nav)
      return __internal_srcdoc_window__(srcdoc) unless srcdoc.nil?
      return __internal_about_blank_window__(url) if Internal::ChildNavigable.matches_about_blank?(url)
      return nil if url.start_with?("javascript:")

      local = Internal::ChildNavigable.window_for_local_url(url)
      return local if local

      delegate = owner_document&.default_view&.navigation_delegate
      return nil unless delegate.respond_to?(:load_frame)

      delegate.load_frame(self, url: url, **nav)
    end

    # Make `window` the child navigable's active window: the previous one's
    # document is no longer fully active, the new one keeps the navigable's
    # name, knows its container, and sends its own navigations here.
    def __internal_install_content_window__(window, name: nil)
      previous = @content_document&.default_view
      new_document = previous.nil? || !previous.equal?(window)
      if new_document && previous&.__internal_initial_about_blank__? && previous.navigable? &&
         previous.origin == window_origin_as_child(window)
        previous.__internal_adopt_document_of__(window)
        window = previous
      elsif new_document && previous
        name = previous.name
        previous.__internal_discard__
      end
      window.frame_element = self
      window.__internal_seed_name__(name)
      # A window still on the default delegate navigates this navigable; one
      # the embedder wired keeps its own.
      if window.navigation_delegate.is_a?(Navigation::NullDelegate)
        window.navigation_delegate = Internal::ChildNavigable::Delegate.new(self)
      end
      @content_document = window.document
      window.document.__internal_process_parsed_iframes__ if new_document && previous
      nil
    end

    # The origin `window`'s document will have as this navigable's document
    # (an about:blank / about:srcdoc one inherits this element's document's).
    def window_origin_as_child(window)
      return window.origin unless Internal::Origin.inherits_origin?(window.location.href)

      owner_document&.default_view&.origin
    end
    private :window_origin_as_child

    # "Run the iframe load event steps": a trusted `load` at this element.
    def __internal_run_iframe_load_event_steps__
      __internal_fire_event__("load")
      nil
    end

    BLANK_DOCUMENT_HTML = Internal::ChildNavigable::BLANK_HTML

    # The initial about:blank document of a new child navigable, as its Window.
    def __internal_initial_about_blank_window__
      win = __internal_about_blank_window__("about:blank")
      win.__internal_initial_about_blank__ = true
      win
    end

    # An about:blank document (its URL `url`, which matches about:blank) whose
    # base URL is its creator's: HTML gives a document whose URL is
    # about:blank the base URL of the document that created it, and without
    # that every relative URL inside the frame — a form's action, a link, an
    # image — would resolve against `about:blank` and go nowhere.
    def __internal_about_blank_window__(url)
      win = Window.new(nil, backend_doc: Backend.parse(BLANK_DOCUMENT_HTML))
      win.location.__internal_set_url__(url)
      win.document.__internal_set_creator_base_url__(owner_document&.base_uri)
      win
    end

    # An iframe srcdoc document: `about:srcdoc`, the attribute's markup,
    # with its creator's base URL.
    def __internal_srcdoc_window__(markup)
      win = Window.new(nil, backend_doc: Backend.parse(markup.to_s.empty? ? BLANK_DOCUMENT_HTML : markup.to_s))
      win.location.__internal_set_url__("about:srcdoc")
      win.document.__internal_set_creator_base_url__(owner_document&.base_uri)
      win
    end

    # The document this iframe's `srcdoc` (or, without one, nothing) makes,
    # built afresh — kept for embedders that build a frame's document
    # themselves.
    def __internal_build_blank_content_document__
      srcdoc = __internal_attribute_value__("srcdoc")
      win = srcdoc.nil? ? __internal_initial_about_blank_window__ : __internal_srcdoc_window__(srcdoc)
      win.__internal_seed_name__(__internal_attribute_value__("name"))
      win.frame_element = self
      win.document
    end

    # An embedder installed the child navigable's document itself (it fetched
    # the frame's `src`): it becomes the active document, with no load event
    # (the embedder fires it when it chooses).
    def __internal_set_content_document__(doc)
      view = doc.respond_to?(:default_view) ? doc.default_view : nil
      unless view
        @content_document = doc
        return
      end

      @navigation_id = (@navigation_id || 0) + 1
      @attributes_processed = true
      @lazy_load_resumption = nil
      __internal_install_content_window__(view, name: __internal_attribute_value__("name"))
    end

    # The target name of this iframe's content navigable, without creating a
    # blank one to ask: until it exists it is the `name` attribute it will be
    # created with. (Window's named properties ask every iframe.)
    def __internal_navigable_target_name__
      view = @content_document&.default_view
      view ? view.name : __internal_attribute_value__("name").to_s
    end

    # The content navigable's window, when it has been created.
    def __internal_built_content_window__
      @content_document&.default_view
    end

    def content_window
      content_document&.default_view
    end

    # `contentDocument` from script: null unless the active document is same
    # origin with this element's node document ("return the content document"
    # checks the origin-domain).
    def __internal_script_content_document__
      doc = content_document
      return nil unless doc

      child = doc.respond_to?(:default_view) ? doc.default_view : nil
      parent = owner_document&.default_view
      return doc unless child && parent
      return doc if child.origin == parent.origin

      nil
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        __internal_script_content_document__
      when "contentWindow"
        content_window
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLObjectElement < HTMLElement
    include Internal::ConstraintValidation

    def content_document
      nil
    end

    def content_window
      nil
    end

    def form
      __internal_form_owner__
    end

    # An `<object>` is a form-associated element, so it carries the whole
    # constraint validation API — and is barred from constraint validation.
    def __internal_barred_from_constraint_validation__? = true

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        content_document
      when "contentWindow"
        content_window
      when "form"
        form
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end

  end

  class HTMLEmbedElement < HTMLElement
  end

  class HTMLParamElement < HTMLElement
  end

  class HTMLMapElement < HTMLElement
    def areas
      @areas ||= HTMLCollection.new do
        @__node__.css("area").map { |n| @document.wrap_node(n) }.compact
      end
    end

    def __js_get__(key)
      case key
      when "areas"
        areas
      else
        super
      end
    end

    def __js_set__(key, value)
      key == "name" ? (self.name = value) : super
    end
  end

  class HTMLFrameElement < HTMLElement; end

  class HTMLFrameSetElement < HTMLElement
    include WindowReflectingHandlers
  end
end
