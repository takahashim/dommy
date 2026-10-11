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
  // The two operations an operator needs of its source and of its subscriber but
  // the IDL does not declare. Symbol-keyed, so a page can neither see them on
  // the prototypes (which `Object.getOwnPropertyNames` and idlharness both walk)
  // nor replace them to get between an Observable and its operators.
  const kSubscribeWith = Symbol("observable-subscribe-with");
  const kAddObserver = Symbol("observable-add-observer");
  const kRemoveObserver = Symbol("observable-remove-observer");

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

  // take()/drop() counts are WebIDL `unsigned long long`. Its conversion answers
  // ZERO for NaN and for either infinity — so `take(NaN)` and `take(Infinity)`
  // both take nothing — while a negative value wraps modulo 2**64 to a number no
  // source will reach, which is Infinity for our purposes.
  function toUnsignedCount(amount) {
    const n = Math.trunc(Number(amount));
    if (!isFinite(n)) return 0;
    if (n < 0) return Infinity;
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

  // The Subscriber an Observable's subscribe callback is handed. Not
  // constructible from script. #private fields, so a detached `next` /
  // `error` / `complete` (called with no receiver) throws TypeError, as the
  // WebIDL receiver check does.
  //
  // One Subscriber serves every subscription made while it is active (the
  // Observable keeps it as its "weak subscriber"): each subscription adds an
  // internal observer, the producer runs once, and the Subscriber closes —
  // its teardowns run — when the last observer's signal aborts, or when the
  // producer completes or errors.
  //
  // Spec: https://wicg.github.io/observable/#subscriber-api
  class Subscriber {
    #token;
    #ac;
    #signal;
    #observers = [];
    #teardowns = [];
    #active = true;

    constructor(token) {
      if (token !== kInternal) throw new TypeError("Illegal constructor");
      this.#token = token;
      this.#ac = new AbortController();
      this.#signal = this.#ac.signal;
    }

    get active() { void this.#token; return this.#active; }
    get signal() { void this.#token; return this.#signal; }

    next(value) {
      void this.#token;
      if (arguments.length < 1) throw new TypeError("Subscriber.next requires 1 argument");
      if (!this.#active) return;
      // A copy: an observer's next steps may subscribe (or unsubscribe) another.
      for (const observer of this.#observers.slice()) observer.next(value);
    }

    error(err) {
      void this.#token;
      if (arguments.length < 1) throw new TypeError("Subscriber.error requires 1 argument");
      if (!this.#active) { reportException(err); return; }
      this.#close(err);
      for (const observer of this.#observers.slice()) observer.error(err);
    }

    complete() {
      void this.#token;
      if (!this.#active) return;
      this.#close(undefined);
      for (const observer of this.#observers.slice()) observer.complete();
    }

    addTeardown(teardown) {
      void this.#token;
      if (!isCallable(teardown)) return;
      if (this.#active) {
        this.#teardowns.push(teardown);
      } else {
        try { teardown.call(undefined); } catch (e) { reportException(e); }
      }
    }

    // "Close a subscription": inactive first (re-entrance is a no-op), then
    // the signal aborts, then the teardowns run in reverse order.
    #close(reason) {
      if (!this.#active) return;
      this.#active = false;
      try { this.#ac.abort(reason); } catch (_e) {}
      const teardowns = this.#teardowns;
      this.#teardowns = [];
      for (let i = teardowns.length - 1; i >= 0; i--) {
        try { teardowns[i].call(undefined); } catch (e) { reportException(e); }
      }
    }

    [kAddObserver](observer) { this.#observers.push(observer); }

    // An observer's own signal aborted: it leaves, and the last one to leave
    // closes the subscription with that signal's reason.
    [kRemoveObserver](observer, reason) {
      if (!this.#active) return;
      const index = this.#observers.indexOf(observer);
      if (index !== -1) this.#observers.splice(index, 1);
      if (this.#observers.length === 0) this.#close(reason);
    }
  }

  Object.defineProperty(Subscriber.prototype, Symbol.toStringTag, {
    value: "Subscriber", configurable: true,
  });

  // An internal observer: next / error / complete steps. Script's callbacks
  // are invoked with "report" (a throw is reported, never propagated); a
  // missing error callback is the default error algorithm, which reports.
  function internalObserverFrom(observer) {
    const invoke = (fn, receiver, args) => {
      try { fn.apply(receiver, args); } catch (e) { reportException(e); }
    };
    if (isCallable(observer)) {
      return { next: (v) => invoke(observer, undefined, [v]), error: reportException, complete: () => {} };
    }
    const o = observer && typeof observer === "object" ? observer : {};
    const next = o.next;
    const error = o.error;
    const complete = o.complete;
    return {
      next: isCallable(next) ? (v) => invoke(next, o, [v]) : () => {},
      error: isCallable(error) ? (e) => invoke(error, o, [e]) : reportException,
      complete: isCallable(complete) ? () => invoke(complete, o, []) : () => {},
    };
  }

  // An operator's own {next?, error?, complete?}, completed with the defaults.
  function completeInternalObserver(observer) {
    return {
      next: observer.next || (() => {}),
      error: observer.error || reportException,
      complete: observer.complete || (() => {}),
    };
  }

  // GetIterator: the iterator the method returns, which must be an object,
  // with its `next` read once.
  // (An async one's `next` is read at its first step instead: see
  // subscribeToAsyncIterable.)
  function getIteratorRecord(value, method, { lazyNext = false } = {}) {
    const iterator = method.call(value);
    if (iterator === null || (typeof iterator !== "object" && typeof iterator !== "function")) {
      throw new TypeError("The iterator is not an object");
    }
    return { iterator, next: lazyNext ? undefined : iterator.next, done: false };
  }

  // CreateAsyncFromSyncIterator, enough for from(): each step's value is
  // awaited, and `return` forwards to the sync iterator's.
  function asyncFromSyncIterator(record) {
    const sync = record.iterator;
    const iterator = {
      next() {
        const result = record.next.call(sync);
        if (result === null || typeof result !== "object") throw new TypeError("Iterator result is not an object");
        const done = !!result.done;
        return Promise.resolve(result.value).then((value) => ({ value, done }));
      },
      return(reason) {
        const ret = getMethod(sync, "return");
        return Promise.resolve(ret === undefined ? { value: reason, done: true } : ret.call(sync, reason));
      },
    };
    return { iterator, next: iterator.next, done: false };
  }

  // from() an async iterable. Errors from next() reach the subscriber in a
  // microtask (through a rejected promise); an abort closes the iterator,
  // with the abort reason, unless it already finished.
  //
  // Spec: https://wicg.github.io/observable/#convert-to-an-observable
  function subscribeToAsyncIterable(value, subscriber) {
    if (subscriber.signal.aborted) return;
    let record;
    try {
      const method = getMethod(value, Symbol.asyncIterator);
      if (method !== undefined) {
        record = getIteratorRecord(value, method, { lazyNext: true });
      } else {
        // GetIterator(async) falls back to the sync iterator protocol.
        const syncMethod = getMethod(value, Symbol.iterator);
        if (syncMethod === undefined) throw new TypeError("The value is not async iterable");
        record = asyncFromSyncIterator(getIteratorRecord(value, syncMethod));
      }
    } catch (e) {
      subscriber.error(e);
      return;
    }
    if (subscriber.signal.aborted) return;
    onConsumerAbort(subscriber.signal, () => {
      if (record.done) return;
      record.done = true;
      // AsyncIteratorClose: what return() throws, or a result that is not an
      // object, rejects the promise it hands back — which nothing awaits, so
      // the page sees it as an unhandled rejection.
      new Promise((resolve) => {
        const ret = getMethod(record.iterator, "return");
        resolve(ret === undefined ? {} : ret.call(record.iterator, subscriber.signal.reason));
      }).then((result) => {
        if (result === null || typeof result !== "object") throw new TypeError("Iterator#return() must return an Object");
      });
    });
    const step = () => {
      if (subscriber.signal.aborted) return;
      let nextPromise;
      try {
        // A throwing `next` getter rejects, so it reaches the subscriber in a
        // microtask like every other error from stepping the iterator.
        if (record.next === undefined) record.next = record.iterator.next;
        nextPromise = Promise.resolve(record.next.call(record.iterator));
      } catch (e) {
        record.done = true;
        nextPromise = Promise.reject(e);
      }
      nextPromise.then(
        (result) => {
          if (result === null || typeof result !== "object") {
            subscriber.error(new TypeError("Iterator result is not an object"));
            return;
          }
          let done;
          let item;
          try {
            done = !!result.done;
            if (!done) item = result.value;
          } catch (e) {
            subscriber.error(e);
            return;
          }
          if (done) {
            record.done = true;
            subscriber.complete();
            return;
          }
          subscriber.next(item);
          step();
        },
        (reason) => subscriber.error(reason),
      );
    };
    step();
  }

  // from() a sync iterable: the values synchronously, until done, an error,
  // or an abort, which closes the iterator unless it already finished.
  function subscribeToIterable(value, subscriber) {
    if (subscriber.signal.aborted) return;
    let record;
    try {
      const method = getMethod(value, Symbol.iterator);
      if (method === undefined) throw new TypeError("The value is not iterable");
      record = getIteratorRecord(value, method);
    } catch (e) {
      subscriber.error(e);
      return;
    }
    if (subscriber.signal.aborted) return;
    // IteratorClose; what it throws is reported, as the abort algorithm runs
    // where no caller could catch it.
    onConsumerAbort(subscriber.signal, () => {
      if (record.done) return;
      record.done = true;
      try {
        const ret = getMethod(record.iterator, "return");
        if (ret === undefined) return;
        const result = ret.call(record.iterator);
        if (result === null || typeof result !== "object") throw new TypeError("Iterator#return() must return an Object");
      } catch (e) {
        reportException(e);
      }
    });
    while (true) {
      let item;
      try {
        const result = record.next.call(record.iterator);
        if (result === null || typeof result !== "object") throw new TypeError("Iterator result is not an object");
        if (result.done) {
          record.done = true;
          subscriber.complete();
          return;
        }
        item = result.value;
      } catch (e) {
        record.done = true;
        subscriber.error(e);
        return;
      }
      subscriber.next(item);
      if (subscriber.signal.aborted) return;
    }
  }

  class Observable {
    #subscribeCallback;
    #weakSubscriber = null;

    constructor(subscribeCallback) {
      if (!isCallable(subscribeCallback)) {
        throw new TypeError("Observable constructor requires a callback function");
      }
      this.#subscribeCallback = subscribeCallback;
    }

    // Public subscribe(). observer may be a next-callback, an observer object,
    // or omitted. options may carry an AbortSignal.
    subscribe(observer, options) {
      this.#subscribe(internalObserverFrom(observer), options || {});
    }

    // Internal subscribe used by operators, with an internal observer of
    // their own.
    [kSubscribeWith](internalObserver, options) {
      this.#subscribe(completeInternalObserver(internalObserver), options || {});
    }

    // Spec: https://wicg.github.io/observable/#observable-subscribe-to-an-observable
    #subscribe(observer, options) {
      const signal = options.signal;
      const shared = this.#weakSubscriber && this.#weakSubscriber.deref();
      if (shared && shared.active) {
        shared[kAddObserver](observer);
        if (signal) {
          if (signal.aborted) shared[kRemoveObserver](observer, signal.reason);
          else onConsumerAbort(signal, () => shared[kRemoveObserver](observer, signal.reason));
        }
        return;
      }

      const subscriber = new Subscriber(kInternal);
      subscriber[kAddObserver](observer);
      this.#weakSubscriber = new WeakRef(subscriber);
      if (signal) {
        if (signal.aborted) subscriber[kRemoveObserver](observer, signal.reason);
        else onConsumerAbort(signal, () => subscriber[kRemoveObserver](observer, signal.reason));
      }
      try {
        this.#subscribeCallback.call(undefined, subscriber);
      } catch (e) {
        subscriber.error(e);
      }
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
        return new Observable((subscriber) => subscribeToAsyncIterable(value, subscriber));
      }

      if (getMethod(value, Symbol.iterator) !== undefined) {
        return new Observable((subscriber) => subscribeToIterable(value, subscriber));
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
        source[kSubscribeWith]({
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
        source[kSubscribeWith]({
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
        source[kSubscribeWith]({
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
        source[kSubscribeWith]({
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
          inner[kSubscribeWith]({
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

        source[kSubscribeWith]({
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
          inner[kSubscribeWith]({
            next: (v) => subscriber.next(v),
            error: (e) => subscriber.error(e),
            complete: () => {
              innerActive = false;
              if (outerComplete) subscriber.complete();
            },
          }, { signal: AbortSignal.any([subscriber.signal, innerController.signal]) });
        };

        source[kSubscribeWith]({
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
        notifierObs[kSubscribeWith]({
          next: () => subscriber.complete(),
          error: () => subscriber.complete(),
          complete: () => {},
        }, { signal: subscriber.signal });
        if (subscriber.signal.aborted) return;
        source[kSubscribeWith]({
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
        source[kSubscribeWith]({
          next: (v) => subscriber.next(v),
          error: (err) => {
            let next;
            try { next = Observable.from(handler(err)); }
            catch (e) { subscriber.error(e); return; }
            next[kSubscribeWith]({
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
        source[kSubscribeWith]({
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
        // The abort callback is for a consumer's unsubscription only: the
        // source finishing (or the next callback throwing) removes it first.
        // Registered before subscribing to the source, so it runs ahead of
        // the source subscription's own teardown; what it throws is reported.
        let abortArmed = isCallable(cfg.abort);
        if (abortArmed) {
          onConsumerAbort(subscriber.signal, () => {
            if (!abortArmed) return;
            try { cfg.abort(subscriber.signal.reason); } catch (e) { reportException(e); }
          });
        }
        source[kSubscribeWith]({
          next: (v) => {
            try { if (isCallable(cfg.next)) cfg.next(v); }
            catch (e) { abortArmed = false; subscriber.error(e); return; }
            subscriber.next(v);
          },
          error: (e) => {
            abortArmed = false;
            try { if (isCallable(cfg.error)) cfg.error(e); }
            catch (thrown) { subscriber.error(thrown); return; }
            subscriber.error(e);
          },
          complete: () => {
            abortArmed = false;
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
      source[kSubscribeWith]({
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

    // Where the global object is not the window itself (it forwards the
    // window's EventTarget methods), the bare `when` / `self.when` is the
    // window's too.
    // (The window may not be installed yet: it is looked up at the call.)
    if (!(globalThis instanceof EventTarget) && !("when" in globalThis)) {
      Object.defineProperty(globalThis, "when", {
        configurable: true, writable: true,
        value: function when(type, options) { return globalThis.window.when(type, options); },
      });
    }
  }
})();
