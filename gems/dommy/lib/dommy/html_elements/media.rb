# frozen_string_literal: true

module Dommy
  # Audio, video and the elements that feed them.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<audio>` / `<video>` shared base. The actual media engine is
  # absent in Dommy — getters return inert values, `play()` returns
  # a resolved Promise, and `pause()` flips `paused` back to true.
  class HTMLMediaElement < HTMLElement
    reflect_url :src
    # The attribute's missing and invalid value default are both
    # implementation-defined; HTML suggests Metadata as the compromise.
    reflect_enumerated preload: { keywords: %w[none metadata auto], missing: "metadata", invalid: "metadata", empty: "auto" },
                       crossorigin: Internal::EnumeratedKeywordSets::CROSS_ORIGIN.merge(js: "crossOrigin"),
                       loading: Internal::EnumeratedKeywordSets::LAZY_LOADING
    reflect_boolean :autoplay, :controls, loop_: { attr: "loop", js: "loop" }, default_muted: "muted"
    # Own __js_call__ methods, on top of Element's.
    NETWORK_EMPTY = 0
    NETWORK_IDLE = 1
    NETWORK_LOADING = 2
    NETWORK_NO_SOURCE = 3

    HAVE_NOTHING = 0
    HAVE_METADATA = 1
    HAVE_CURRENT_DATA = 2
    HAVE_FUTURE_DATA = 3
    HAVE_ENOUGH_DATA = 4

    def current_src
      src
    end

    def muted
      @__muted == true || reflected_boolean("muted")
    end

    def muted=(v)
      @__muted = !!v
    end

    def paused
      @__paused.nil? ? true : @__paused
    end

    def ended
      false
    end

    def seeking
      false
    end

    def volume
      @__volume.nil? ? 1.0 : @__volume
    end

    def volume=(v)
      @__volume = v.to_f
    end

    def playback_rate
      @__rate.nil? ? 1.0 : @__rate
    end

    def playback_rate=(v)
      @__rate = v.to_f
    end

    def default_playback_rate
      @__default_rate.nil? ? 1.0 : @__default_rate
    end

    def default_playback_rate=(v)
      @__default_rate = v.to_f
    end

    def current_time
      @__current_time.to_f
    end

    def current_time=(v)
      @__current_time = v.to_f
    end

    def duration
      Float::NAN
    end

    def network_state
      NETWORK_EMPTY
    end

    def ready_state
      HAVE_NOTHING
    end

    def play
      @__paused = false
      promise = PromiseValue.new(@document.default_view)
      promise.fulfill(nil)
      promise
    end

    def pause
      @__paused = true
      nil
    end

    def load
      nil
    end

    def can_play_type(_type)
      # spec: "" | "maybe" | "probably". We don't decode → "".
      ""
    end

    def __js_get__(key)
      case key
      when "currentSrc"
        current_src
      when "muted"
        muted
      when "paused"
        paused
      when "ended"
        ended
      when "seeking"
        seeking
      when "volume"
        volume
      when "playbackRate"
        playback_rate
      when "defaultPlaybackRate"
        default_playback_rate
      when "currentTime"
        current_time
      when "duration"
        duration
      when "networkState"
        network_state
      when "readyState"
        ready_state
      when "NETWORK_EMPTY"
        NETWORK_EMPTY
      when "NETWORK_IDLE"
        NETWORK_IDLE
      when "NETWORK_LOADING"
        NETWORK_LOADING
      when "NETWORK_NO_SOURCE"
        NETWORK_NO_SOURCE
      when "HAVE_NOTHING"
        HAVE_NOTHING
      when "HAVE_METADATA"
        HAVE_METADATA
      when "HAVE_CURRENT_DATA"
        HAVE_CURRENT_DATA
      when "HAVE_FUTURE_DATA"
        HAVE_FUTURE_DATA
      when "HAVE_ENOUGH_DATA"
        HAVE_ENOUGH_DATA
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "muted"
        self.muted = value
      when "volume"
        self.volume = value
      when "playbackRate"
        self.playback_rate = value
      when "defaultPlaybackRate"
        self.default_playback_rate = value
      when "currentTime"
        self.current_time = value
      else
        super
      end
    end

    js_methods %w[play pause load canPlayType]
    def __js_call__(method, args)
      case method
      when "play"
        play
      when "pause"
        pause
      when "load"
        load
      when "canPlayType"
        can_play_type(args[0])
      else
        super
      end
    end
  end

  class HTMLAudioElement < HTMLMediaElement
  end

  class HTMLVideoElement < HTMLMediaElement
    reflect_url :poster
    reflect_boolean plays_inline: "playsinline"
    reflect_ulong :width, :height

    def video_width
      width
    end

    def video_height
      height
    end

    js_accessor :width, :height
    js_readable :video_width, :video_height

  end

  class HTMLSourceElement < HTMLElement
    reflect_url :src
    reflect_string :type, :media, :srcset, :sizes
    reflect_ulong :width, :height

    js_accessor :width, :height

  end

  class HTMLTrackElement < HTMLElement
    reflect_url :src
    reflect_string :srclang, :label
    reflect_enumerated kind: { keywords: %w[subtitles captions descriptions chapters metadata],
                               missing: "subtitles", invalid: "metadata" }
    reflect_boolean default_: { attr: "default", js: "default" }
    NONE = 0
    LOADING = 1
    LOADED = 2
    ERROR = 3

    def ready_state
      NONE
    end

    js_readable :ready_state
  end

  class HTMLPictureElement < HTMLElement
  end

  # `<img>` — reflected URL/dimension attributes. Dommy has no real
  # image loading, so `complete`/`naturalWidth`/`naturalHeight` are
  # static (complete=true, dimensions=0).
  class HTMLImageElement < HTMLElement
    # `name`, `align`, `border`, `hspace`, `vspace` and `longDesc` are obsolete
    # but still reflected — `name` in particular is what puts an image in the
    # document's named getter, so renaming one has to move it there.
    reflect_url :src, long_desc: "longdesc"
    reflect_string :alt, :sizes, :srcset, :name, :align, :border, use_map: "usemap"
    reflect_enumerated decoding: { keywords: %w[sync async auto], missing: "auto", invalid: "auto" },
                       loading: Internal::EnumeratedKeywordSets::LAZY_LOADING,
                       crossorigin: Internal::EnumeratedKeywordSets::CROSS_ORIGIN.merge(js: "crossOrigin"),
                       referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy"),
                       fetch_priority: Internal::EnumeratedKeywordSets::FETCH_PRIORITY
    reflect_boolean :is_map
    # [ReflectSetter]: the setters reflect as `unsigned long`, and the getters
    # are prose — HTML's "determining the dimensions", which reports the rendered
    # size when the image is being rendered and the natural size when it has one.
    # Dommy renders nothing and fetches nothing, so both are absent and the
    # algorithm reduces to its last step: the content attribute, parsed, or 0.
    # https://html.spec.whatwg.org/multipage/embedded-content-other.html#determine-dimensions
    reflect_ulong_setter :width, :height

    def width
      parse_html_non_negative_integer(__internal_attribute_value__("width")) || 0
    end

    def height
      parse_html_non_negative_integer(__internal_attribute_value__("height")) || 0
    end

    # No real loader → these are constants.
    def natural_width
      0
    end

    def natural_height
      0
    end

    def complete
      true
    end

    def current_src
      src
    end

    # `x` / `y`: the left / top border edge of the element's first CSS layout
    # box, or 0 when it has none — which, with no layout, is always.
    def x = 0
    def y = 0

    js_readable :x, :y

    # `decode()`: a promise that a microtask later rejects with an
    # EncodingError when the image's node document is not fully active (it
    # has no browsing context) or its current request is broken (see
    # image_request_broken?), and otherwise resolves once the image is
    # "completely available" and decoded — a task later, since dommy fetches
    # and decodes nothing.
    def decode
      window = @document.default_view
      scheduler = @document.respond_to?(:__internal_scheduler__) ? @document.__internal_scheduler__ : nil
      # A document with no browsing context still has the scheduler of the
      # window that made it (DOMParser), which is all a promise needs.
      promise = PromiseValue.new(window || (scheduler && SchedulerHolder.new(scheduler)))
      run = proc do
        if window.nil? || image_request_broken?
          promise.reject(DOMException::EncodingError.new("The source image cannot be decoded."))
        else
          queue_element_task { promise.fulfill(nil) }
        end
        nil
      end
      scheduler ? scheduler.queue_microtask(run) : run.call
      promise
    end

    SchedulerHolder = Struct.new(:scheduler)
    private_constant :SchedulerHolder

    js_methods %w[decode]
    def __js_call__(method, args)
      case method
      when "decode" then decode
      else super
      end
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "naturalWidth"
        natural_width
      when "naturalHeight"
        natural_height
      when "complete"
        complete
      when "currentSrc"
        current_src
      else
        super
      end
    end

    private

    include Internal::ElementTasks

    # Whether "update the image data" leaves the current request broken: the
    # source set has no candidate (srcset's are its non-empty comma-separated
    # entries, src counts unless it is empty), or the one it falls to is src
    # and src does not parse as a URL. A srcset candidate's URL is not
    # checked: dommy does not select among them.
    def image_request_broken?
      srcset = __internal_attribute_value__("srcset").to_s
      return false if srcset.split(",").any? { |candidate| !candidate.strip.empty? }

      raw = __internal_attribute_value__("src")
      return true if raw.nil? || raw.empty?

      base = @document.base_uri.to_s
      Internal::UrlParser.parse(raw, base.empty? ? nil : base, encoding: @document.character_encoding)
      false
    rescue Internal::UrlParser::Failure
      true
    end
  end

  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
end
