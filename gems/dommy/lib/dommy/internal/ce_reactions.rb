# frozen_string_literal: true

require_relative "ce_reactions_table"

module Dommy
  module Internal
    # HTML §4.13.6 "Custom element reactions": the custom element reactions
    # stack of element queues, each element's custom element reaction queue,
    # and the backup element queue.
    #
    # A reaction is never run in the middle of the DOM operation that caused
    # it. Each [CEReactions] member a script calls pushes an element queue
    # (#scope); the reactions the operation enqueues collect on the elements
    # in that queue, and run, element by element, when the member returns.
    # What happens with no [CEReactions] member on the stack — a mutation from
    # a member without it, or from the user agent — goes on the backup element
    # queue, processed in a microtask.
    #
    # One stack serves the whole process, as the spec gives one to each
    # similar-origin window agent: Dommy's windows (a page and its iframes)
    # share one JS realm, so they are one agent.
    #
    # Ruby code driving the DOM directly is not a script on a JS stack, and has
    # no microtask checkpoint coming after it: when the element's document has
    # no JS engine wired to its scheduler, the backup queue is processed right
    # away instead — so `doc.body.append(el)` has run `connected_callback` by
    # the time it returns, as it always has.
    module CEReactions
      # The custom element state and definition an element carries, and its
      # custom element reaction queue. Held by the element's wrapper and handed
      # on to the wrapper that replaces it (an upgrade to a Ruby-class
      # definition re-wraps the node), so an element's queue survives the
      # upgrade that its own reactions are being processed for.
      class ElementData
        attr_accessor :state, :definition, :wrapper, :is_value
        attr_reader :reactions

        def initialize(wrapper, state, is_value = nil)
          @wrapper = wrapper
          @state = state
          @is_value = is_value
          @definition = nil
          @reactions = []
        end

        def custom? = @state == "custom"
      end

      # A reaction's element queue entry: the element's data, so a re-wrapped
      # element is still the same entry.
      @stack = []
      @backup = []
      @processing_backup = false
      @invoking = 0
      # Interface member sets, by Ruby class (see #member?).
      @member_sets = {}

      class << self
        # Run the block as a [CEReactions] member: push an element queue, run
        # it, pop the queue and invoke its reactions — even when the block
        # raised, whose exception is then re-raised.
        def scope
          @stack.push([])
          begin
            yield
          ensure
            invoke(@stack.pop)
          end
        end

        # Make `methods` of `klass` [CEReactions] for Ruby callers too: a
        # composite operation — markup parsed and inserted, a subtree cloned —
        # enqueues reactions at several of its steps, which must run when it
        # returns rather than one by one as they are enqueued. Only the
        # outermost call is a scope: one made from inside another operation
        # (the adopt an insertion does) or from a script's [CEReactions] call
        # (see Js::HostBridge) is a step of that one, whose reactions run
        # when it returns.
        def scoped(klass, *methods)
          reactions = self
          klass.prepend(Module.new do
            methods.each do |name|
              define_method(name) do |*args, &block|
                return super(*args, &block) if reactions.active?

                result = reactions.scope { super(*args, &block) }
                # An upgrade to a Ruby-class definition re-wraps the element
                # (a clone, say): hand back the wrapper it has now.
                result.respond_to?(:__internal_current_wrapper__) ? result.__internal_current_wrapper__ : result
              end
              ruby2_keywords(name)
            end
          end)
        end

        # Whether an element queue is on the stack, or reactions are being
        # invoked.
        def active?
          !@stack.empty? || @invoking.positive?
        end

        # Whether a script's use of `name` on `object` is a [CEReactions]
        # member: `kind` is :call (an operation), :set (an attribute setter, or
        # the interface's special setter when no attribute has the name) or
        # :delete (the special deleter).
        def member?(object, kind, name)
          sets = member_sets(object)
          return false unless sets

          case kind
          when :call then sets[:operations].include?(name)
          when :set then sets[:attributes].include?(name) || sets[:setter]
          when :delete then sets[:deleter]
          else false
          end
        end

        # HTML "enqueue a custom element callback reaction". `element` must
        # have a definition; a callback the definition does not have, or an
        # attributeChangedCallback for an attribute it does not observe, is
        # not enqueued.
        def enqueue_callback(element, callback_name, args = [])
          data = element.__internal_ce_data__
          definition = data.definition
          return unless definition

          callback = callback_name
          if callback_name == "connectedMoveCallback" && !definition.callback?(callback_name)
            # No connectedMoveCallback: a move runs disconnectedCallback and
            # then connectedCallback in its place.
            return unless definition.callback?("connectedCallback") || definition.callback?("disconnectedCallback")

            callback = :move_fallback
          elsif !definition.callback?(callback_name)
            return
          end
          if callback_name == "attributeChangedCallback"
            return unless definition.observes?(args[0].to_s)
          end

          data.reactions << [:callback, callback, args]
          enqueue_element(data)
        end

        # HTML "enqueue a custom element upgrade reaction".
        def enqueue_upgrade(element, definition)
          data = element.__internal_ce_data__
          data.reactions << [:upgrade, definition]
          enqueue_element(data)
        end

        # HTML "enqueue an element on the appropriate element queue".
        def enqueue_element(data)
          unless @stack.empty?
            @stack.last << data
            return
          end

          @backup << data
          return if @processing_backup

          scheduler = microtask_scheduler_for(data)
          if scheduler
            @processing_backup = true
            scheduler.queue_microtask(proc { process_backup_queue })
          elsif @invoking.zero?
            process_backup_queue
          end
          # Otherwise reactions are being invoked: the element's own are taken
          # by the loop that is running them, and the rest of the backup queue
          # is processed once it is done (see #invoke).
        end

        # HTML "invoke custom element reactions" in `queue`.
        def invoke(queue)
          @invoking += 1
          begin
            until queue.empty?
              data = queue.shift
              reactions = data.reactions
              until reactions.empty?
                reaction = reactions.shift
                run(data, reaction)
              end
            end
          ensure
            @invoking -= 1
          end
          process_backup_queue if @invoking.zero? && @stack.empty? && !@processing_backup && !@backup.empty?
        end

        private

        def process_backup_queue
          @processing_backup = true
          invoke(@backup)
        ensure
          @processing_backup = false
        end

        def run(data, reaction)
          case reaction[0]
          when :upgrade
            definition = reaction[1]
            begin
              definition.upgrade(data)
            rescue StandardError => e
              definition.report(e)
            end
          when :callback
            definition = data.definition
            return unless definition

            begin
              if reaction[1] == :move_fallback
                definition.invoke(data.wrapper, "disconnectedCallback", []) if definition.callback?("disconnectedCallback")
                definition.invoke(data.wrapper, "connectedCallback", []) if definition.callback?("connectedCallback")
              else
                definition.invoke(data.wrapper, reaction[1], reaction[2])
              end
            rescue StandardError => e
              definition.report(e)
            end
          end
        end

        # The engine's microtask queue the element's document schedules on,
        # or nil when no engine is wired (Ruby drives the DOM itself).
        def microtask_scheduler_for(data)
          document = data.wrapper.owner_document if data.wrapper.respond_to?(:owner_document)
          scheduler = document.__internal_scheduler__ if document.respond_to?(:__internal_scheduler__)
          return nil unless scheduler.respond_to?(:native_microtask_scheduler) && scheduler.native_microtask_scheduler

          scheduler
        end

        def member_sets(object)
          klass = object.class
          return @member_sets[klass] if @member_sets.key?(klass)

          @member_sets[klass] = build_member_sets(object)
        end

        # Beyond the table, CSSOM §6.7.1 gives CSSStyleProperties a
        # [CEReactions] attribute per CSS property (camel-cased, webkit-cased
        # and dashed) in prose, so any property assignment on a declaration
        # counts.
        def build_member_sets(object)
          return nil unless defined?(Dommy::Js::DomInterfaces)

          chain = Dommy::Js::DomInterfaces.chain_for(object)
          entries = chain.filter_map { |name| TABLE[name] }
          return nil if entries.empty?

          special = entries.flat_map { |e| e[:special] || [] }
          {
            attributes: entries.flat_map { |e| e[:attributes] || [] }.to_set,
            operations: entries.flat_map { |e| e[:operations] || [] }.to_set,
            setter: special.include?("setter") || chain.include?("CSSStyleDeclaration"),
            deleter: special.include?("deleter")
          }
        end
      end
    end
  end
end
