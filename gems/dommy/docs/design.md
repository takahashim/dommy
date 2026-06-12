# Dommy Design Document

## Purpose

Dommy is a pure-Ruby DOM polyfill built on top of [Nokogiri::HTML5](https://nokogiri.org/) that facilitates parsing arbitrary HTML into a DOM tree, its manipulation, and (re)serialization into HTML form. It exposes browser-like DOM semantics so view, component, and request specs can verify DOM structure and behavior without spinning up a real browser.

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

### Pluggable Backend Abstraction

Dommy abstracts the underlying DOM parser behind a backend interface:

- Nokogiri::HTML5 (current default): Mature, battle-tested, C-based via libxml2
- Nokolexbor (in progress): Rust-based via Lexbor, faster parsing

This abstraction allows teams to choose their performance/stability tradeoff and enables future parser adoptions without rewriting Dommy.

## Unresolved Issues

### 1. Nokolexbor Backend Maturity

Nokolexbor has two known API gaps vs Nokogiri:

- **Namespace binding**: `add_namespace_definition(nil, href)` doesn't update the element's own namespace. Workaround: check both `node.namespace` and `node.namespace_definitions[0]`.
- **Object identity**: Fresh Ruby wrappers for the same C node have different `object_id`. Workaround: use node pointer in Hash keys, not `object_id`.

Both are documented in **NOKOLEXBOR_IMPROVEMENTS_SPEC.md** and **NOKOLEXBOR_NODE_IDENTITY_SPEC.md**. Once Nokolexbor improvements land, these workarounds vanish.

**Decision needed:** Should we maintain dual Nokogiri/Nokolexbor support indefinitely, or migrate fully once Nokolexbor matures?

### 2. Visibility Detection (resolved)

Resolved by the CSS cascade layer (`internal/css/`, see css-cascade.md): with the makiri-backed CSS parser available, `display: none` / `visibility: hidden` from `<style>` sheets is detected through computed styles (UA + author + inline cascade, inheritance included). Sheetless documents keep the original HTML-level fast path, which also remains the fallback when makiri is absent. Still out of scope: layout-dependent invisibility and media-query-conditional rules (cascade Phase 2).

### 3. Default Backend Selection

As Nokolexbor matures, should the default switch from Nokogiri to Nokolexbor? What's the deprecation path for Nokogiri support?

## References

Implementation-related projects:

- [Nokogiri](https://nokogiri.org/)
- [Nokolexbor](https://github.com/serpapi/nokolexbor/)

Core web platform specifications:

- [DOM Standard](https://dom.spec.whatwg.org/)
- [HTML Standard](https://html.spec.whatwg.org/)
- [URL Standard](https://url.spec.whatwg.org/)
- [File API](https://w3c.github.io/FileAPI/)
- [Storage Standard](https://storage.spec.whatwg.org/)
