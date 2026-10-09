# frozen_string_literal: true

module Capybara
  module Dommy
    # Capybara waits for a page by retrying a failed query, sleeping between
    # attempts until `default_max_wait_time` of real time has passed. That is
    # how a real browser, which changes on its own, is waited for. A Dommy
    # page with JavaScript changes only when its virtual clock moves, and the
    # driver is what moves it — so for such a page the wait is a span of the
    # page's own time: Capybara's 2 seconds are 2 seconds of the clock, which
    # the page is let run through, timer by timer, until the query passes.
    #
    # Prepended to Capybara::Node::Base, this takes over `synchronize` for a
    # JavaScript-enabled Dommy driver (other drivers keep Capybara's loop).
    # After a failed attempt the driver lets the page move on (Driver#wait_on):
    # a completion a worker handed back is delivered, or the clock moves
    # straight to the page's next timer when it is due within what is left of
    # the wait. A 300 ms debounce therefore costs one retry, not 300 ms. When
    # nothing within the wait can change the page, the query is tried once
    # more after a reload (a node may have gone stale) and then fails at once,
    # not after the wait has passed in real time. Only an open WebSocket or
    # EventSource, which the app can push to at any moment, is waited for in
    # real time, for at most the wait.
    module VirtualWait
      # A bound on the retries of one wait, against a page that keeps the
      # clock busy for nothing (a timer that re-arms itself at no delay
      # without being clamped).
      MAX_ATTEMPTS = 10_000

      def synchronize(seconds = nil, errors: nil)
        return super unless driver.is_a?(Capybara::Dommy::Driver) && driver.javascript?
        return yield if session.synchronized

        seconds = session_options.default_max_wait_time if [nil, true].include?(seconds)
        seconds = 0 unless seconds
        session.synchronized = true
        wait = driver.begin_wait(seconds)
        real_time = Capybara::Helpers.timer(expire_in: seconds)
        reloaded = false
        attempts = 0
        begin
          yield
        rescue StandardError => e
          session.raise_server_error!
          raise e unless catch_error?(e, errors)
          raise e if (attempts += 1) > MAX_ATTEMPTS

          if driver.wait_on(wait)
            reloaded = false
          elsif driver.open_connections? && !real_time.expired?
            sleep session_options.default_retry_interval
          elsif !reloaded
            reloaded = true
          else
            raise e
          end
          reload if session_options.automatic_reload
          retry
        ensure
          session.synchronized = false
          driver.end_wait
        end
      end
    end
  end
end

Capybara::Node::Base.prepend(Capybara::Dommy::VirtualWait)
