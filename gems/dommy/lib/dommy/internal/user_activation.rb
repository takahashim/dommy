# frozen_string_literal: true

module Dommy
  module Internal
    # HTML §6.4 "Tracking user activation", mixed into Window: the window's
    # last activation timestamp and last history-action activation
    # timestamp, the sticky / transient / history-action activation states
    # read off them, the activation notification steps a user's input runs,
    # and the steps that consume an activation.
    #
    # Timestamps are the window's current high resolution time
    # (`performance.now()`, Dommy's virtual clock), so a test advancing
    # virtual time past TRANSIENT_ACTIVATION_DURATION sees the activation
    # expire.
    #
    # Host contract: a Window — #frame_element, #frame_windows, #origin,
    # #navigable?, #top_window, #document, and #__internal_close_watcher_manager__.
    module UserActivation
      # The transient activation duration, in milliseconds. HTML leaves it to
      # the user agent ("at most a few seconds"); Chromium's is 5 seconds.
      TRANSIENT_ACTIVATION_DURATION = 5000.0

      # Event types that, when trusted, are activation triggering input
      # events (keydown, pointerdown and pointerup have conditions; see
      # .activation_triggering?).
      TRIGGER_TYPES = %w[keydown mousedown pointerdown pointerup touchend].freeze

      # HTML "activation triggering input event": a trusted keydown that is
      # neither Esc nor a key the user agent reserves (Dommy reserves none),
      # mousedown, a mouse pointerdown, a non-mouse pointerup, or touchend.
      def self.activation_triggering?(event)
        return false unless event.is_a?(Event) && event.__js_get__("isTrusted") == true

        case event.type
        when "keydown" then event.__js_get__("key") != "Escape"
        when "mousedown", "touchend" then true
        when "pointerdown" then event.__js_get__("pointerType") == "mouse"
        when "pointerup" then event.__js_get__("pointerType") != "mouse"
        else false
        end
      end

      # The part of HTML's showPicker() steps about activation: without
      # transient activation, a NotAllowedError; then (after the block, the
      # caller's remaining checks) "show the picker, if applicable", which
      # consumes the activation — Dommy shows no picker.
      def self.show_picker_if_applicable(element, mutable:)
        window = element.owner_document.default_view
        unless window.respond_to?(:__internal_transient_activation__?) && window.__internal_transient_activation__?
          raise DOMException::NotAllowedError, "showPicker() requires a user gesture."
        end

        yield if block_given?
        window.__internal_consume_user_activation__ if mutable
        nil
      end

      # Whether `document`'s origin differs from its top-level origin (it is
      # in a cross-origin frame).
      def self.cross_origin_frame?(document)
        window = document.default_view
        return false unless window.respond_to?(:top_window)

        top = window.top_window
        !top.nil? && !top.equal?(window) && top.origin != window.origin
      end

      # The current high resolution time given this window.
      def __internal_current_high_resolution_time__
        __js_get__("performance").now.to_f
      end

      def __internal_last_activation_timestamp__ = (@last_activation_timestamp ||= Float::INFINITY)

      def __internal_last_activation_timestamp__=(value)
        @last_activation_timestamp = value
      end

      def __internal_last_history_action_activation_timestamp__ =
        (@last_history_action_activation_timestamp ||= Float::INFINITY)

      # HTML "sticky activation": the current time is at or after the last
      # activation timestamp (never true while it is +∞; always true once it
      # is -∞, a consumed activation).
      def __internal_sticky_activation__?
        __internal_current_high_resolution_time__ >= __internal_last_activation_timestamp__
      end

      # HTML "transient activation": at or after the last activation
      # timestamp, and before it plus the transient activation duration.
      def __internal_transient_activation__?
        now = __internal_current_high_resolution_time__
        last = __internal_last_activation_timestamp__
        now >= last && now < last + TRANSIENT_ACTIVATION_DURATION
      end

      # HTML "history-action activation": the two timestamps differ.
      def __internal_history_action_activation__?
        __internal_last_history_action_activation_timestamp__ != __internal_last_activation_timestamp__
      end

      # HTML's "activation notification steps", which a user interaction
      # runs before dispatching an activation triggering input event at a
      # node of this window's document: this window, the windows of its
      # ancestor navigables, and those of its same-origin descendant
      # navigables get the current time as their last activation timestamp,
      # and each window's close watcher manager hears of the activation.
      def __internal_notify_activation__
        windows = [self]
        ancestor = self
        while (frame = ancestor.frame_element) && (ancestor = frame.owner_document&.default_view)
          break if windows.include?(ancestor)

          windows << ancestor
        end
        origin = self.origin
        each_descendant_window(self) do |window|
          windows << window if window.origin == origin && !windows.include?(window)
        end
        windows.each do |window|
          window.__internal_last_activation_timestamp__ = window.__internal_current_high_resolution_time__
          window.__internal_close_watcher_manager__.notify_user_activation
        end
        nil
      end

      # HTML "consume user activation": every window of this window's
      # top-level traversable that has ever been activated loses its
      # transient activation (its timestamp becomes -∞).
      def __internal_consume_user_activation__
        each_window_of_top_level_traversable do |window|
          next if window.__internal_last_activation_timestamp__ == Float::INFINITY

          window.__internal_last_activation_timestamp__ = -Float::INFINITY
        end
        nil
      end

      # HTML "consume history-action user activation".
      def __internal_consume_history_action_user_activation__
        each_window_of_top_level_traversable do |window|
          window.instance_variable_set(:@last_history_action_activation_timestamp,
            window.__internal_last_activation_timestamp__)
        end
        nil
      end

      # The window's associated UserActivation (navigator.userActivation).
      def __internal_user_activation__ = (@user_activation ||= Dommy::UserActivation.new(self))

      private

      def each_window_of_top_level_traversable(&block)
        return unless navigable?

        top = top_window || self
        yield top
        each_descendant_window(top, &block)
      end

      def each_descendant_window(window, seen = [], &block)
        window.frame_windows.each do |child|
          next if child.nil? || seen.include?(child)

          seen << child
          yield child
          each_descendant_window(child, seen, &block)
        end
      end
    end
  end

  # HTML's UserActivation interface (`navigator.userActivation`): whether
  # its window has sticky activation (hasBeenActive) and transient
  # activation (isActive).
  class UserActivation
    def initialize(window)
      @window = window
    end

    def has_been_active = @window.__internal_sticky_activation__?
    def is_active = @window.__internal_transient_activation__?

    def __js_get__(key)
      case key
      when "hasBeenActive" then has_been_active
      when "isActive" then is_active
      else Bridge::ABSENT
      end
    end
  end
end
