// Observable / Subscriber polyfill (WICG Observable) + EventTarget.prototype.when.
//
// QuickJS is a real JS engine, so the reactive primitive is implemented in JS
// and evaluated into the VM after the DOM interface prototypes are seeded (so
// `EventTarget.prototype` exists). The only host integration points are
// EventTarget (addEventListener/removeEventListener), AbortController/AbortSignal,
// and reporting an unhandled exception to the global error handler.
(function () {
  "use strict";
  if (typeof globalThis.Observable === "function") return;

  const kInternal = Symbol("observable-internal");

  // "Report the exception" — the WHATWG operation, which the page reaches as
  // `self.reportError`. Handing it the error there rather than building an
  // ErrorEvent here means an Observable error nobody caught is reported exactly
  // as one thrown from a listener is: the same `error` event at the window, the
  // same choice of the frame the PAGE owns for filename/lineno (this file's own
  // frames are not the page's), and the same console/host notification when the
  // page doesn't handle it — none of which a bare dispatch from here did.
  //
  // Reporting must never throw into the caller, and a realm with no window (a
  // bare VM, a unit harness) has nowhere to report to.
  function reportException(error) {
    try {
      const w = globalThis.window;
      if (w && typeof w.reportError === "function") w.reportError(error);
    } catch (_e) {
      // Best effort: the error being reported must not be replaced by an error
      // from reporting it.
    }
  }

  function isCallable(v) { return typeof v === "function"; }

  // take()/drop() counts are WebIDL `unsigned long long`: a negative value
  // wraps to the maximum (effectively unlimited), as does a non-finite value.
  function toUnsignedCount(amount) {
    const n = Math.trunc(Number(amount));
    if (!isFinite(n) || n < 0) return Infinity;
    return n;
  }

  // TC39 GetMethod(value, key): undefined for an absent (null/undefined)
  // property, the function if callable, and a TypeError if present but not
  // callable. The property read may itself throw (a getter) — that propagates.
  function getMethod(value, key) {
    const method = value[key];
    if (method === undefined || method === null) return undefined;
    if (!isCallable(method)) throw new TypeError(String(key) + " is not a function");
    return method;
  }

  // The Subscriber handed to an Observable's initializer. Not constructible from
  // script. Uses #private fields so a detached `next`/`error`/`complete`
  // (called with no receiver) throws TypeError — matching the WebIDL receiver
  // check the spec mandates.
  class Subscriber {
    #token;
    #ac;
    #signal;
    #next;
    #error;
    #complete;
    #teardowns = [];
    #closed = false;

    constructor(token, observer) {
      if (token !== kInternal) throw new TypeError("Illegal constructor");
      this.#token = token;
      this.#ac = new AbortController();
      this.#signal = this.#ac.signal;
      this.#next = isCallable(observer && observer.next) ? observer.next : null;
      this.#error = isCallable(observer && observer.error) ? observer.error : null;
      this.#complete = isCallable(observer && observer.complete) ? observer.complete : null;
    }

    get active() { return !this.#signal.aborted; }
    get signal() { return this.#signal; }

    next(value) {
      // Touch a private field first so a receiver-less call throws TypeError.
      void this.#token;
      if (arguments.length < 1) throw new TypeError("Subscriber.next requires 1 argument");
      if (this.#signal.aborted) return;
      if (this.#next) {
        try { this.#next.call(undefined, value); }
        catch (e) { reportException(e); }
      }
    }

    error(err) {
      void this.#token;
      if (arguments.length < 1) throw new TypeError("Subscriber.error requires 1 argument");
      if (this.#signal.aborted) { reportException(err); return; }
      const cb = this.#error;
      this.#close(err);
      if (cb) {
        try { cb.call(undefined, err); }
        catch (e) { reportException(e); }
      } else {
        reportException(err);
      }
    }

    complete() {
      void this.#token;
      if (this.#signal.aborted) return;
      const cb = this.#complete;
      this.#close(undefined);
      if (cb) {
        try { cb.call(undefined); }
        catch (e) { reportException(e); }
      }
    }

    addTeardown(teardown) {
      void this.#token;
      if (!isCallable(teardown)) return;
      if (this.#signal.aborted) {
        try { teardown.call(undefined); } catch (e) { reportException(e); }
      } else {
        this.#teardowns.push(teardown);
      }
    }

    // Abort the subscriber's signal (reason for error()), then run teardowns
    // LIFO. After this, active is false and the signal is aborted — before any
    // observer complete()/error() callback is invoked.
    #close(reason) {
      if (this.#closed) return;
      this.#closed = true;
      try { this.#ac.abort(reason); } catch (_e) {}
      const teardowns = this.#teardowns;
      this.#teardowns = [];
      for (let i = teardowns.length - 1; i >= 0; i--) {
        try { teardowns[i].call(undefined); } catch (e) { reportException(e); }
      }
    }

    // Internal: abort because the consumer's signal aborted (unsubscribe).
    _abortConsumer(reason) { this.#close(reason); }
  }

  Object.defineProperty(Subscriber.prototype, Symbol.toStringTag, {
    value: "Subscriber", configurable: true,
  });

  function normalizeObserver(observer) {
    if (isCallable(observer)) return { next: observer };
    if (observer && typeof observer === "object") return observer;
    return {};
  }

  class Observable {
    #subscribeCallback;

    constructor(subscribeCallback) {
      if (!isCallable(subscribeCallback)) {
        throw new TypeError("Observable constructor requires a callback function");
      }
      this.#subscribeCallback = subscribeCallback;
    }

    // Public subscribe(). observer may be a next-callback, an observer object,
    // or omitted. options may carry an AbortSignal.
    subscribe(observer, options) {
      this._subscribeWith(normalizeObserver(observer), options || {});
    }

    // Internal subscribe used by subscribe() and by operators. internalObserver
    // is a plain {next?, error?, complete?}.
    _subscribeWith(internalObserver, options) {
      const subscriber = new Subscriber(kInternal, internalObserver);
      const outer = options && options.signal;
      if (outer) {
        if (outer.aborted) subscriber._abortConsumer(outer.reason);
        else onConsumerAbort(outer, () => subscriber._abortConsumer(outer.reason));
      }
      try {
        this.#subscribeCallback.call(undefined, subscriber);
      } catch (e) {
        subscriber.error(e);
      }
      return subscriber;
    }

    static from(value) {
      if (value instanceof Observable) return value;
      if (value === null || (typeof value !== "object" && typeof value !== "function")) {
        throw new TypeError("Observable.from: value is not convertible to an Observable");
      }

      // Commit to a conversion by probing the protocol method (TC39 GetMethod:
      // a present-but-not-callable @@asyncIterator/@@iterator is a TypeError,
      // not a silent fall-through to the next branch). The method is re-read at
      // subscribe time too — it is never cached.
      if (getMethod(value, Symbol.asyncIterator) !== undefined) {
        return new Observable((subscriber) => {
          const method = getMethod(value, Symbol.asyncIterator);
          if (method === undefined) { subscriber.error(new TypeError("@@asyncIterator was removed")); return; }
          let iterator;
          try { iterator = method.call(value); }
          catch (e) { subscriber.error(e); return; }
          subscriber.addTeardown(() => {
            if (iterator && isCallable(iterator.return)) {
              try { Promise.resolve(iterator.return()).then(undefined, () => {}); } catch (_e) {}
            }
          });
          const pump = () => {
            if (subscriber.signal.aborted) return;
            let p;
            try { p = iterator.next(); }
            catch (e) { subscriber.error(e); return; }
            Promise.resolve(p).then(
              (result) => {
                if (subscriber.signal.aborted) return;
                if (result === null || typeof result !== "object") {
                  subscriber.error(new TypeError("Iterator result is not an object"));
                  return;
                }
                if (result.done) { subscriber.complete(); return; }
                subscriber.next(result.value);
                pump();
              },
              (e) => subscriber.error(e),
            );
          };
          pump();
        });
      }

      if (getMethod(value, Symbol.iterator) !== undefined) {
        return new Observable((subscriber) => {
          let method;
          try { method = getMethod(value, Symbol.iterator); }
          catch (e) { subscriber.error(e); return; }
          if (method === undefined) { subscriber.error(new TypeError("@@iterator was removed")); return; }
          let iterator;
          try { iterator = method.call(value); }
          catch (e) { subscriber.error(e); return; }
          subscriber.addTeardown(() => {
            if (iterator && isCallable(iterator.return)) {
              try { iterator.return(); } catch (_e) {}
            }
          });
          while (true) {
            if (subscriber.signal.aborted) return;
            let result;
            try { result = iterator.next(); }
            catch (e) { subscriber.error(e); return; }
            if (result === null || typeof result !== "object") {
              subscriber.error(new TypeError("Iterator result is not an object"));
              return;
            }
            if (result.done) { subscriber.complete(); return; }
            subscriber.next(result.value);
          }
        });
      }

      if (isCallable(value.then)) {
        return new Observable((subscriber) => {
          Promise.resolve(value).then(
            (v) => { subscriber.next(v); subscriber.complete(); },
            (e) => subscriber.error(e),
          );
        });
      }

      throw new TypeError("Observable.from: value is not convertible to an Observable");
    }

    // ---- transform operators (return an Observable) ----

    map(mapper) {
      if (!isCallable(mapper)) throw new TypeError("map: mapper must be a function");
      const source = this;
      return new Observable((subscriber) => {
        let index = 0;
        source._subscribeWith({
          next: (value) => {
            let mapped;
            try { mapped = mapper(value, index++); }
            catch (e) { subscriber.error(e); return; }
            subscriber.next(mapped);
          },
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    filter(predicate) {
      if (!isCallable(predicate)) throw new TypeError("filter: predicate must be a function");
      const source = this;
      return new Observable((subscriber) => {
        let index = 0;
        source._subscribeWith({
          next: (value) => {
            let keep;
            try { keep = predicate(value, index++); }
            catch (e) { subscriber.error(e); return; }
            if (keep) subscriber.next(value);
          },
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    take(amount) {
      amount = toUnsignedCount(amount);
      const source = this;
      return new Observable((subscriber) => {
        if (amount === 0) { subscriber.complete(); return; }
        let remaining = amount;
        source._subscribeWith({
          next: (value) => {
            subscriber.next(value);
            if (--remaining === 0) subscriber.complete();
          },
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    drop(amount) {
      amount = toUnsignedCount(amount);
      const source = this;
      return new Observable((subscriber) => {
        let remaining = amount;
        source._subscribeWith({
          next: (value) => {
            if (remaining > 0) { remaining--; return; }
            subscriber.next(value);
          },
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    flatMap(mapper) {
      if (!isCallable(mapper)) throw new TypeError("flatMap: mapper must be a function");
      const source = this;
      return new Observable((subscriber) => {
        let index = 0;
        let outerComplete = false;
        let active = 0;
        const queue = [];
        let subscribing = false;

        const subscribeToInner = (value) => {
          active++;
          let inner;
          try { inner = Observable.from(mapper(value, index++)); }
          catch (e) { subscriber.error(e); return; }
          inner._subscribeWith({
            next: (v) => subscriber.next(v),
            error: (e) => subscriber.error(e),
            complete: () => {
              active--;
              if (queue.length > 0) {
                subscribeToInner(queue.shift());
              } else if (outerComplete && active === 0) {
                subscriber.complete();
              }
            },
          }, { signal: subscriber.signal });
        };

        source._subscribeWith({
          next: (value) => {
            if (active > 0) queue.push(value);
            else subscribeToInner(value);
          },
          error: (e) => subscriber.error(e),
          complete: () => {
            outerComplete = true;
            if (active === 0 && queue.length === 0) subscriber.complete();
          },
        }, { signal: subscriber.signal });
      });
    }

    switchMap(mapper) {
      if (!isCallable(mapper)) throw new TypeError("switchMap: mapper must be a function");
      const source = this;
      return new Observable((subscriber) => {
        let index = 0;
        let outerComplete = false;
        let innerController = null;
        let innerActive = false;

        const startInner = (value) => {
          if (innerController) innerController.abort();
          innerController = new AbortController();
          innerActive = true;
          let inner;
          try { inner = Observable.from(mapper(value, index++)); }
          catch (e) { subscriber.error(e); return; }
          inner._subscribeWith({
            next: (v) => subscriber.next(v),
            error: (e) => subscriber.error(e),
            complete: () => {
              innerActive = false;
              if (outerComplete) subscriber.complete();
            },
          }, { signal: AbortSignal.any([subscriber.signal, innerController.signal]) });
        };

        source._subscribeWith({
          next: (value) => startInner(value),
          error: (e) => subscriber.error(e),
          complete: () => {
            outerComplete = true;
            if (!innerActive) subscriber.complete();
          },
        }, { signal: subscriber.signal });
      });
    }

    takeUntil(notifier) {
      const source = this;
      return new Observable((subscriber) => {
        const notifierObs = Observable.from(notifier);
        // The notifier's first next() OR error() completes the subscriber (the
        // error is NOT mirrored); the notifier completing is a no-op.
        notifierObs._subscribeWith({
          next: () => subscriber.complete(),
          error: () => subscriber.complete(),
          complete: () => {},
        }, { signal: subscriber.signal });
        if (subscriber.signal.aborted) return;
        source._subscribeWith({
          next: (v) => subscriber.next(v),
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    catch(handler) {
      if (!isCallable(handler)) throw new TypeError("catch: handler must be a function");
      const source = this;
      return new Observable((subscriber) => {
        source._subscribeWith({
          next: (v) => subscriber.next(v),
          error: (err) => {
            let next;
            try { next = Observable.from(handler(err)); }
            catch (e) { subscriber.error(e); return; }
            next._subscribeWith({
              next: (v) => subscriber.next(v),
              error: (e) => subscriber.error(e),
              complete: () => subscriber.complete(),
            }, { signal: subscriber.signal });
          },
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    finally(callback) {
      if (!isCallable(callback)) throw new TypeError("finally: callback must be a function");
      const source = this;
      return new Observable((subscriber) => {
        subscriber.addTeardown(() => callback());
        source._subscribeWith({
          next: (v) => subscriber.next(v),
          error: (e) => subscriber.error(e),
          complete: () => subscriber.complete(),
        }, { signal: subscriber.signal });
      });
    }

    inspect(inspector) {
      const source = this;
      const cfg = isCallable(inspector) ? { next: inspector } : (inspector || {});
      return new Observable((subscriber) => {
        try { if (isCallable(cfg.subscribe)) cfg.subscribe(); }
        catch (e) { subscriber.error(e); return; }
        if (isCallable(cfg.abort)) {
          // Register before subscribing to the source so the inspector's abort
          // tap fires ahead of the source subscription's own teardown.
          onConsumerAbort(subscriber.signal, () => {
            try { cfg.abort(subscriber.signal.reason); } catch (_e) {}
          });
        }
        source._subscribeWith({
          next: (v) => {
            try { if (isCallable(cfg.next)) cfg.next(v); }
            catch (e) { subscriber.error(e); return; }
            subscriber.next(v);
          },
          error: (e) => {
            try { if (isCallable(cfg.error)) cfg.error(e); } catch (_e) {}
            subscriber.error(e);
          },
          complete: () => {
            try { if (isCallable(cfg.complete)) cfg.complete(); }
            catch (e) { subscriber.error(e); return; }
            subscriber.complete();
          },
        }, { signal: subscriber.signal });
      });
    }

    // ---- promise-returning operators ----
    //
    // Each is the same subscription (see subscribeForPromise) with a different
    // observer, so each writes only its observer.

    toArray(options) {
      return subscribeForPromise(this, options, (resolve) => {
        const values = [];
        return { next: (v) => values.push(v), complete: () => resolve(values) };
      });
    }

    forEach(callback, options) {
      return subscribeForPromise(this, options, (resolve, reject, abort) => {
        if (!isCallable(callback)) return rejectWith(reject, "forEach: callback must be a function");
        let index = 0;
        return {
          next: (v) => {
            try { callback(v, index++); }
            catch (e) { reject(e); abort(e); }
          },
          complete: () => resolve(undefined),
        };
      });
    }

    first(options) {
      return subscribeForPromise(this, options, (resolve, reject, abort) => ({
        next: (v) => { resolve(v); abort(); },
        complete: () => reject(new RangeError("first(): source completed without emitting a value")),
      }));
    }

    last(options) {
      return subscribeForPromise(this, options, (resolve, reject) => {
        let has = false;
        let lastValue;
        return {
          next: (v) => { has = true; lastValue = v; },
          complete: () => {
            if (has) resolve(lastValue);
            else reject(new RangeError("last(): source completed without emitting a value"));
          },
        };
      });
    }

    find(predicate, options) {
      return subscribeForPromise(this, options, (resolve, reject, abort) => {
        if (!isCallable(predicate)) return rejectWith(reject, "find: predicate must be a function");
        let index = 0;
        return {
          next: (v) => {
            let matched;
            try { matched = predicate(v, index++); }
            catch (e) { reject(e); abort(e); return; }
            if (matched) { resolve(v); abort(); }
          },
          complete: () => resolve(undefined),
        };
      });
    }

    some(predicate, options) {
      return subscribeForPromise(this, options, (resolve, reject, abort) => {
        if (!isCallable(predicate)) return rejectWith(reject, "some: predicate must be a function");
        let index = 0;
        return {
          next: (v) => {
            let matched;
            try { matched = predicate(v, index++); }
            catch (e) { reject(e); abort(e); return; }
            if (matched) { resolve(true); abort(); }
          },
          complete: () => resolve(false),
        };
      });
    }

    every(predicate, options) {
      return subscribeForPromise(this, options, (resolve, reject, abort) => {
        if (!isCallable(predicate)) return rejectWith(reject, "every: predicate must be a function");
        let index = 0;
        return {
          next: (v) => {
            let matched;
            try { matched = predicate(v, index++); }
            catch (e) { reject(e); abort(e); return; }
            if (!matched) { resolve(false); abort(); }
          },
          complete: () => resolve(true),
        };
      });
    }

    reduce(reducer, initialValue, options) {
      // An absent initialValue is not the same as an explicit undefined: without
      // one the first value becomes the accumulator, and a source that emits
      // nothing has no answer to give.
      const hasInitial = arguments.length >= 2;
      return subscribeForPromise(this, options, (resolve, reject, abort) => {
        if (!isCallable(reducer)) return rejectWith(reject, "reduce: reducer must be a function");
        let acc = initialValue;
        let hasAcc = hasInitial;
        let index = 0;
        return {
          next: (v) => {
            if (!hasAcc) { acc = v; hasAcc = true; index++; return; }
            try { acc = reducer(acc, v, index++); }
            catch (e) { reject(e); abort(e); }
          },
          complete: () => {
            if (!hasAcc) reject(new TypeError("reduce: no values and no initial value"));
            else resolve(acc);
          },
        };
      });
    }
  }

  // Every promise-returning operator subscribes the same way: with a controller
  // of its own, so it can stop the producer the moment it has its answer, and
  // with the caller's signal wired to that controller. What differs is only how
  // the values are turned into a settlement, so that is all `build` supplies —
  // the {next, complete} steps, built from the settlement functions and an
  // `abort` that tears the source subscription down (which is both how an
  // operator with its answer unsubscribes, and how one whose callback threw
  // makes the source run its teardown). An error from the source always rejects,
  // so no operator writes that.
  //
  // A build that cannot proceed — a callback argument that is not callable —
  // rejects and returns null, because the spec asks for a rejected promise
  // there, not a synchronous throw.
  function subscribeForPromise(source, options, build) {
    return new Promise((resolve, reject) => {
      const controller = new AbortController();
      wireConsumerAbort(options, controller, reject);
      const signal = controller.signal;
      if (signal.aborted) return;
      const steps = build(resolve, reject, (reason) => controller.abort(reason));
      if (!steps) return;
      source._subscribeWith({
        next: steps.next,
        error: (e) => reject(e),
        complete: steps.complete,
      }, { signal });
    });
  }

  function rejectWith(reject, message) {
    reject(new TypeError(message));
    return null;
  }

  // React to a consumer (downstream) signal aborting. Prefer an abort ALGORITHM
  // — it runs before the signal's "abort" event, so a subscription tears down
  // ahead of any external abort listener (the spec's downstream-before-upstream
  // ordering) — and fall back to a one-shot listener when the host AbortSignal
  // doesn't expose the algorithm hook.
  function onConsumerAbort(signal, fn) {
    if (typeof signal.__internalAddAbortAlgorithm === "function") signal.__internalAddAbortAlgorithm(fn);
    else signal.addEventListener("abort", fn, { once: true });
  }

  // Wire a promise-returning operator's own controller to the caller's (outer)
  // signal: when the outer aborts, reject the promise and abort the controller
  // (which tears down the source subscription). The operator subscribes the
  // source with `controller.signal`.
  function wireConsumerAbort(options, controller, reject) {
    const outer = options && options.signal;
    if (!outer) return;
    const onAbort = () => { reject(outer.reason); try { controller.abort(outer.reason); } catch (_e) {} };
    if (outer.aborted) onAbort();
    else onConsumerAbort(outer, onAbort);
  }

  Object.defineProperty(Observable.prototype, Symbol.toStringTag, {
    value: "Observable", configurable: true,
  });

  globalThis.Observable = Observable;
  globalThis.Subscriber = Subscriber;

  // EventTarget.prototype.when(type, options) → Observable of events.
  if (typeof globalThis.EventTarget === "function") {
    Object.defineProperty(EventTarget.prototype, "when", {
      configurable: true, writable: true,
      value: function when(type, options) {
        const target = this;
        const opts = options || {};
        return new Observable((subscriber) => {
          const handler = (event) => subscriber.next(event);
          target.addEventListener(type, handler, {
            signal: subscriber.signal,
            capture: !!opts.capture,
            passive: opts.passive,
          });
        });
      },
    });
  }
})();
