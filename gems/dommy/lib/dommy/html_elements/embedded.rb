# frozen_string_literal: true

module Dommy
  # Elements that host content from somewhere else.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  class HTMLIFrameElement < HTMLElement
    reflect_url :src
    reflect_token_list :sandbox
    reflect_string :srcdoc, :name, :allow, :loading, referrer_policy: "referrerpolicy"
    reflect_boolean allow_fullscreen: "allowfullscreen"
    reflect_string :width, :height

    # The nested browsing context's document. An integration/test layer may
    # inject one via `__internal_set_content_document__` (e.g. the `src`
    # resource); otherwise a connected iframe gets a lazily-created blank
    # about:blank document (with its own Window), matching a browser where
    # `iframe.contentDocument` is non-null once the frame is in a document.
    # A disconnected iframe has no browsing context, so contentDocument is null.
    def content_document
      return @content_document if @content_document
      return nil unless respond_to?(:is_connected?) && is_connected?
      # An iframe with a `src` (or `srcdoc`) is navigated by the host / test layer
      # (Dommy doesn't fetch), which injects the document via
      # `__internal_set_content_document__`; only a truly blank iframe gets the
      # auto about:blank document here, so we don't shadow a pending navigation.
      return nil unless get_attribute("src").to_s.empty? && get_attribute("srcdoc").nil?

      @content_document = __internal_build_blank_content_document__
    end

    BLANK_DOCUMENT_HTML = "<!DOCTYPE html><html><head></head><body></body></html>"

    # Build the nested document + its Window for a browsing context with
    # nothing to fetch — a blank frame, or one whose content is its `srcdoc`.
    # Back-links the Window to this frame (so getComputedStyle can detect a
    # non-rendered frame's content).
    #
    # Its document URL is `about:blank` (`about:srcdoc` when the content came
    # from the attribute), which is what a browser reports and what the frame's
    # own `location` reads. A Window left at the library's default URL reported
    # `http://localhost/` instead.
    #
    # Its BASE URL is this element's document's, which is the other half of the
    # same rule: HTML gives a document whose URL is about:blank the base URL of
    # the document that created it, and without that half every relative URL
    # inside the frame — a form's action, a link, an image — would resolve
    # against `about:blank` and go nowhere.
    def __internal_build_blank_content_document__
      srcdoc = get_attribute("srcdoc")
      html = srcdoc.to_s.empty? ? BLANK_DOCUMENT_HTML : srcdoc.to_s
      win = Window.new(nil, backend_doc: Backend.parse(html))
      win.location.__internal_set_url__(srcdoc.nil? ? "about:blank" : "about:srcdoc")
      doc = win.document
      doc.__internal_set_creator_base_url__(owner_document&.base_uri)
      win.frame_element = self if win.respond_to?(:frame_element=)
      doc
    end

    def __internal_set_content_document__(doc)
      @content_document = doc
      # Back-link the nested window to its hosting frame, so getComputedStyle can
      # detect content inside a non-rendered (display:none / disconnected) frame.
      view = doc.respond_to?(:default_view) ? doc.default_view : nil
      view.frame_element = self if view.respond_to?(:frame_element=)
    end

    def content_window
      # Go through the lazy accessor so a blank browsing context is created on
      # first `contentWindow` access too (not only via `contentDocument`).
      content_document&.default_view
    end

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
    reflect_url :data
    reflect_string :type, :name, use_map: "usemap"
    reflect_string :width, :height

    def content_document
      nil
    end

    def content_window
      nil
    end

    def form
      closest("form")
    end

    # An `<object>` is a form-associated element, so it carries the whole
    # constraint validation API — and is barred from constraint validation, so
    # every member of it reports the never-invalid answer.
    def validity
      ValidityState.new
    end

    def will_validate
      false
    end

    def validation_message
      ""
    end

    def check_validity
      true
    end

    def report_validity
      true
    end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

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
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
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

    js_methods %w[checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      when "setCustomValidity"
        set_custom_validity(args[0])
      else
        super
      end
    end
  end

  class HTMLEmbedElement < HTMLElement
    reflect_url :src
    reflect_string :type
    reflect_string :width, :height

    js_accessor :width, :height

  end

  class HTMLParamElement < HTMLElement
    reflect_string :name, :value
  end

  class HTMLMapElement < HTMLElement
    reflect_string :name
    def areas
      HTMLCollection.new do
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
