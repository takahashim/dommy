# frozen_string_literal: true

module Dommy
  # The HTMLHyperlinkElementUtils IDL mixin, shared by <a> and <area>. The
  # `href` content attribute, parsed against the document base URL, is the
  # element's URL; every getter reads a component of it and every setter
  # changes that component the way the URL API does, then writes the
  # serialization back into the attribute. Without an href there is no URL
  # and the getters return the empty string (":" for protocol); an href that
  # does not parse reads back as written.
  #
  # Spec: https://html.spec.whatwg.org/multipage/links.html#htmlhyperlinkelementutils
  module HyperlinkUtils
    URL_COMPONENTS = %w[origin protocol username password host hostname port pathname search hash].freeze

    # WebIDL stringifier: `String(link)` / `link.toString()` is its href (the
    # resolved absolute URL), not the element's serialization.
    def to_s
      href
    end

    def href
      raw = @__node__["href"]
      return "" if raw.nil?

      url = hyperlink_url
      url ? url.href : raw
    end

    def href=(value)
      set_attribute("href", value.to_s)
    end

    def origin
      url = hyperlink_url
      url ? url.origin : ""
    end

    def protocol
      url = hyperlink_url
      url ? url.protocol : ":"
    end

    def protocol=(value)
      change_url { |url| url.protocol = value }
    end

    def username
      hyperlink_url&.username.to_s
    end

    def username=(value)
      change_url { |url| url.username = value }
    end

    def password
      hyperlink_url&.password.to_s
    end

    def password=(value)
      change_url { |url| url.password = value }
    end

    def host
      hyperlink_url&.host.to_s
    end

    def host=(value)
      change_url { |url| url.host = value }
    end

    def hostname
      hyperlink_url&.hostname.to_s
    end

    def hostname=(value)
      change_url { |url| url.hostname = value }
    end

    def port
      hyperlink_url&.port.to_s
    end

    def port=(value)
      change_url { |url| url.port = value }
    end

    def pathname
      hyperlink_url&.pathname.to_s
    end

    def pathname=(value)
      change_url { |url| url.pathname = value }
    end

    def search
      hyperlink_url&.search.to_s
    end

    def search=(value)
      change_url { |url| url.search = value }
    end

    def hash
      hyperlink_url&.hash.to_s
    end

    def hash=(value)
      change_url { |url| url.hash = value }
    end

    def __js_get__(key)
      case key
      when "href" then href
      when "origin" then origin
      when "protocol" then protocol
      when "username" then username
      when "password" then password
      when "host" then host
      when "hostname" then hostname
      when "port" then port
      when "pathname" then pathname
      when "search" then search
      when "hash" then self.hash
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "href" then self.href = value
      when "protocol" then self.protocol = value
      when "username" then self.username = value
      when "password" then self.password = value
      when "host" then self.host = value
      when "hostname" then self.hostname = value
      when "port" then self.port = value
      when "pathname" then self.pathname = value
      when "search" then self.search = value
      when "hash" then self.hash = value
      else super
      end
    end

    private

    # HTML "reinitialize url": the href attribute parsed against the
    # document base URL, or nil when there is none or it does not parse.
    def hyperlink_url
      raw = @__node__["href"]
      return nil if raw.nil?

      base = @document.base_uri.to_s
      URL.new(raw, base.empty? ? nil : base)
    rescue Bridge::TypeError
      nil
    end

    # A setter: nothing without a URL; otherwise the change, then "update
    # href" with the serialization.
    def change_url
      url = hyperlink_url
      return unless url

      yield url
      set_attribute("href", url.href)
    end
  end
end
