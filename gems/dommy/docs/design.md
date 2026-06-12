# Dommy Design Document

## Purpose

Dommy is a pure-Ruby DOM polyfill built on top of Makiri that facilitates parsing arbitrary HTML into a DOM tree, its manipulation, and (re)serialization into HTML form. It exposes browser-like DOM semantics so view, component, and request specs can verify DOM structure and behavior without spinning up a real browser.

## Goals

- Provide a lightweight DOM implementation for Ruby environments
- Mirror browser DOM APIs as closely as possible
- Enable fast, deterministic testing without browser overhead

## Non-Goals

- JavaScript execution — No JS engine; `<script>` tags are inert
- Real layout engine — `getBoundingClientRect()` returns zero; CSS engine not included
- Media rendering — Canvas, WebGL, image/video playback not supported
- Headless browser features — No real browser process or chromium integration
- CSS parsing or computed styles — Beyond inline `style=` attributes

## Technical Approach

### Event Model

Dommy implements the full DOM event system: capture/bubble phases, `composedPath()` across shadow boundaries, `stopPropagation()`, and `AbortSignal` listener cleanup. Events are dispatch-driven; there's no real UI, so user gestures are simulated via script.

Spec references:

- [DOM Standard: Events](https://dom.spec.whatwg.org/#events)
- [DOM Standard: AbortSignal](https://dom.spec.whatwg.org/#interface-abortsignal)

### Custom Elements & Shadow DOM

Full lifecycle support: `connectedCallback`, `disconnectedCallback`, `attributeChangedCallback`. Shadow DOM works with open/closed modes and slot resolution. Event retargeting across shadow boundaries is implemented.

Spec references:

- [HTML Standard: Custom elements](https://html.spec.whatwg.org/multipage/custom-elements.html)
- [DOM Standard: Shadow tree](https://dom.spec.whatwg.org/#shadow-trees)

### Async & Scheduler

Promise, microtasks, and macrotasks (timers, requestIdleCallback) are all synchronous and deterministic. Time advances via `advance_time(ms)`. The `.await` method unwraps a Promise for use in test assertions.

Spec references:

- [HTML Standard: Timers](https://html.spec.whatwg.org/multipage/timers-and-user-prompts.html#timers)
- [HTML Standard: Event loops](https://html.spec.whatwg.org/multipage/webappapis.html#event-loops)
- [W3C Draft: requestIdleCallback](https://w3c.github.io/requestidlecallback/)

### Storage & Files

localStorage/sessionStorage per window, Blob/File in-memory, FormData field serialization, DataTransfer for drag-and-drop. Blob URLs work via the `blob:dommy/<id>` scheme.

Spec references:

- [File API](https://w3c.github.io/FileAPI/)
- [XMLHttpRequest Standard: FormData](https://xhr.spec.whatwg.org/#interface-formdata)
- [HTML Standard: Drag and drop](https://html.spec.whatwg.org/multipage/dnd.html)
- [Storage Standard](https://storage.spec.whatwg.org/)
- [URL Standard](https://url.spec.whatwg.org/)

## References

Implementation-related projects:

- [Makiri](https://github.com/takahashim/makiri/)

Core web platform specifications:

- [DOM Standard](https://dom.spec.whatwg.org/)
- [HTML Standard](https://html.spec.whatwg.org/)
- [URL Standard](https://url.spec.whatwg.org/)
- [File API](https://w3c.github.io/FileAPI/)
- [Storage Standard](https://storage.spec.whatwg.org/)
