# Changelog

## Unreleased

### Added

- `Scheduler#external_work_in_flight?` says whether a fetch handed to a network executor has not come back yet; `begin_external_work` and `end_external_work` bracket such work for an embedder's own workers.
- `Dommy::Interaction::EventSynthesis.drag_and_drop(source, target, pause:)` drags with the mouse after HTML's drag-and-drop processing model: `dragstart` at the draggable element pressed, `drag`, `dragenter`, `dragleave` and `dragover` over the source and then the target, `drop` when a `dragover` was canceled with an allowed `dropEffect`, and `dragend`.
- A drag's `DataTransfer` is writable only in `dragstart` and readable only in `drop`: in `dragover` and the other drag events `getData` returns `""` and `setData` does nothing.
- Declarative shadow DOM: a `<template shadowrootmode="open">` (or `"closed"`) in a page attaches a shadow root to its parent element, holding the template's contents, and the template is gone — `shadowrootdelegatesfocus`, `shadowrootserializable`, `shadowrootclonable`, `shadowrootslotassignment="manual"` and `shadowrootcustomelementregistry` (a null registry) set the root's flags. The first such template wins: a host that already has a shadow root, an element that cannot host one (`<progress>`, a `<template>`) or a custom element whose definition disables shadow keeps the template as an ordinary one. This holds for the page parse (`Dommy.parse`, `Dommy::Browser`, iframes, `Dommy::Rack` responses), `document.write`, and inside template contents and other declarative shadow trees; the page's scripts in those shadow trees run at boot in the order the parser met them. `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `createContextualFragment`, `DOMParser` and `createHTMLDocument()` documents never attach them (DOM's "allow declarative shadow roots").
- `element.setHTMLUnsafe(html, {runScripts})` and `shadowRoot.setHTMLUnsafe(html, {runScripts})`: parse with declarative shadow roots allowed and replace the children (a template's contents for a `<template>`), using the HTML parser even in an XML document; scripts stay inert unless `runScripts: true`. `Document.parseHTMLUnsafe(html)` returns a new `text/html` document at `about:blank` that allows declarative shadow roots. (The `sanitizer` option is ignored: there is no Sanitizer.)
- `element.getHTML({serializableShadowRoots, shadowRoots})` and `shadowRoot.getHTML(...)`: a host whose shadow root is serializable (with `serializableShadowRoots: true`) or listed in `shadowRoots` serializes it first, as `<template shadowrootmode="open" shadowrootdelegatesfocus="" shadowrootserializable="" shadowrootslotassignment="manual" shadowrootclonable="" shadowrootcustomelementregistry="">…</template>`, nested shadow roots and template contents included.
- `attachShadow({mode, clonable, serializable, slotAssignment})` and `shadowRoot.clonable` / `shadowRoot.serializable`. Cloning a host whose shadow root is clonable — `cloneNode(true)`, `cloneNode(false)`, `importNode`, `Range#cloneContents`, a template's contents — clones the shadow root with it.
- An element created with `{is: "x-y"}` and no `is` attribute serializes `is="x-y"` in `innerHTML`, `outerHTML` and `getHTML()`.
- `HTMLScriptElement.supports(type)`: true for `"classic"`, `"module"`, `"importmap"` and `"speculationrules"`, matched exactly (`supports("Module")` and `supports("text/javascript")` are false).
- A `<script type=module>` inserted by script runs — inline or with `src` — in a task of its own, through the page's import map and module loader, and an external one fires `load` (or `error` when its fetch fails).
- `window.print()` fires trusted `beforeprint` and `afterprint` at the window (and its child frames' windows) and counts the call in `window.__test_print_calls__`; a `print()` made while the document is still loading waits for the end of the load.
- `window.close()`, `window.closed`, `window.stop()`, `window.focus()`, `window.blur()`, `moveTo`, `moveBy`, `resizeBy`, `captureEvents`, `releaseEvents` and `window.external` exist. `close()` closes only a top-level window whose session history holds a single entry (`closed` turns true, and the request is in `__test_close_calls__`); `stop()` drops a navigation the embedder has not performed yet.
- `window.locationbar`, `menubar`, `personalbar`, `scrollbars`, `statusbar` and `toolbar` are `BarProp` objects (`{visible: true}`, the same object each read); `window.status` keeps what was assigned; `isSecureContext` is true for https:, file:, localhost and 127.0.0.1 pages and false for other http: ones; `crossOriginIsolated` and `originAgentCluster` are false; `screenX`/`screenY`/`screenLeft`/`screenTop` are 0.
- An iframe's `contentWindow.parent` and `.top` are the window that contains it, `.frameElement` is the iframe, `.name` starts as the iframe's `name` attribute and can be assigned, and `.opener` is null; once the iframe is removed, `parent`, `top` and `frameElement` are null, `name` is `""` and `closed` is true.
- `window.open(url, target)` navigates and returns an existing window for `_self`, `_parent`, `_top` or the name of a frame (`window.open("#x", "_self") === window`). A new browsing context (`_blank`, an unknown name) is not created: `open()` returns null and the attempt is in `window.__test_open_calls__`; an embedder's navigation delegate that answers `open_window` can supply one.
- `pageshow` fires after `load`, as a `PageTransitionEvent` with `persisted` false; `new PageTransitionEvent("pageshow", {persisted: true})` works; `PopStateEvent#hasUAVisualTransition` is false.
- `Dommy::Browser#on_before_unload { |window, event| ... }`: before a cross-document navigation the browser fires a trusted, cancelable `beforeunload`; a page that cancels it (or sets `returnValue`) is asked about through the handler, and without one the navigation proceeds.
- `navigator.appCodeName` (`"Mozilla"`), `appName` (`"Netscape"`), `appVersion`, `product` (`"Gecko"`), `productSub`, `vendorSub` (`""`), `oscpu`, `taintEnabled()`, `javaEnabled()`, `pdfViewerEnabled` (false), and empty `navigator.plugins` / `navigator.mimeTypes`; `navigator.webdriver` is true. `Navigator#compatibility_mode = :gecko | :chrome | :webkit` picks HTML's navigator compatibility mode (Gecko by default).
- `Dommy::StorageProvider`: the windows of one browsing session share Web Storage — `localStorage` per origin, `sessionStorage` per origin for the session, kept across navigations. `Dommy::Browser` and `Dommy::Rack::Session` install one for every page they show (and their frames), so a value one page stores is there on the next page of the same origin, and a change made in one window fires a trusted `storage` event (with `key`, `oldValue`, `newValue`, `url`, `storageArea`) at the session's other windows of that origin. A lone window keeps a private provider.
- `document.referrer` is the page a link, form or script navigation came from (`Dommy::Browser`, under the default strict-origin-when-cross-origin policy; `Dommy::Rack::Session`, from the request's `Referer`).
- `DOMTokenList#supports` (`list.supports(token)` in JS): ASCII-case-insensitive membership in the attribute's supported tokens — `link.relList` (`alternate`, `dns-prefetch`, `expect`, `icon`, `manifest`, `modulepreload`, `next`, `pingback`, `preconnect`, `prefetch`, `preload`, `search`, `stylesheet`), `a`/`area`/`form` `relList` (`noreferrer`, `noopener`, `opener`), `iframe.sandbox` (the `allow-*` flags) and `blocking` (`render`); a list without supported tokens throws `TypeError` (`el.classList.supports("x")`, `link.sizes.supports("any")`).
- `blocking` on `<link>`, `<script>` and `<style>`: a `[SameObject, PutForwards=value]` DOMTokenList over the `blocking` attribute (`script.blocking = "render"`).
- `form.rel`, reflecting the `rel` attribute.
- `img.decode()`: a promise that rejects with an `EncodingError` DOMException when the image has nothing to load (no `src`/`srcset`, an empty `src`, a `src` that is not a URL) or its document has no browsing context, and otherwise resolves a task later.
- `img.x` / `img.y` (always `0`: no layout) and `img.fetchPriority` (`"high"`, `"low"` or `"auto"`, the default for a missing or unknown value).
- `script.crossOrigin` (a CORS settings attribute like `img.crossOrigin`: `null` when absent, `"anonymous"` for `""` or an unknown value), `script.fetchPriority` and `link.fetchPriority`.
- `a.referrerPolicy` / `area.referrerPolicy`, limited to the referrer policy tokens (`"NO-REFERRER"` reads `"no-referrer"`, an unknown value `""`).
- `template.shadowRootMode` (`"open"`, `"closed"` or `""`), `shadowRootSlotAssignment` (`"named"` by default, or `"manual"`), and the boolean `shadowRootDelegatesFocus`, `shadowRootSerializable`, `shadowRootClonable` plus the string `shadowRootCustomElementRegistry`, reflecting the declarative shadow root attributes.
- `col.span` / `colgroup.span` (default 1, clamped to 1–1000: `span="5000"` reads `1000`), `li.type`, `ul.type`, and `video.loading` / `audio.loading` (`"lazy"` or `"eager"`).
- `Dommy::Internal::JsNumber.to_string(x)`: ECMAScript's Number::toString (shortest round-trip digits, `"5"`, `"1e+25"`, `"1e-7"`, `"0.000001"`, `-0` → `"0"`), and `Dommy::Internal::ReflectedAttributes.parse_floating_point_number(str)`: HTML's rules for parsing floating-point number values (`" 1.5px"` → `1.5`, `"1.e2"` → `100.0`, `"0x1A"` → `0.0`, `"\v7"` → `nil`).
- Event handler IDL attributes are accessors on the interface prototypes: `"onclick" in HTMLElement.prototype`, `Object.getOwnPropertyDescriptor(HTMLElement.prototype, "onclick").set`, `Document.prototype.onreadystatechange`, `Window.prototype.onload`, `HTMLBodyElement.prototype.onhashchange` and `Element.prototype.onfullscreenchange`.
- `onanimationcancel`, `ontransitionrun`, `ontransitionstart`, `ontransitionend`, `ontransitioncancel`, `onselectionchange`, `onpagereveal`, `onpageswap` and the legacy `onwebkitanimationend` / `onwebkitanimationiteration` / `onwebkitanimationstart` / `onwebkittransitionend` handlers, as IDL attributes and content attributes; the WebKit ones run for their camel-cased event types (`webkitAnimationEnd`).
- `shadowRoot.onslotchange`.
- `CSSRule.KEYFRAMES_RULE`, `CSSRule.KEYFRAME_RULE` and `WheelEvent.DOM_DELTA_PIXEL` / `DOM_DELTA_LINE` / `DOM_DELTA_PAGE`.
- Named access on the Window object: `window.someId` is the element with that id, `window.frameName` is the child frame's window (`window.frameName === iframe.contentWindow`, following a later `contentWindow.name = …`), the `name` of an `embed`, `form`, `img` or `object` element names it too, and several matches are a live `HTMLCollection`. `"someId" in window` is true, but the names never shadow a window member or a script's global (`window.alert`, `globalThis.x = 1`), are not own or enumerable properties (`window.hasOwnProperty("someId")` is false), and an assignment (`window.someId = 1`) shadows them until deleted.
- An `<iframe>` gets its child navigable the moment it is connected to a document that has a browsing context: `contentWindow` / `contentDocument` are non-null at once, also when it has a `src` (even `about:blank#foo`), and the first document is the initial about:blank, with its container's origin. A parser-inserted iframe gets its navigable when script boot replays the parse (or on first access in a document that is never booted); one in a `DOMParser` / `createHTMLDocument` document has none.
- Setting, changing or removing an iframe's `src` or `srcdoc` navigates its child navigable from a task: `srcdoc` gives an `about:srcdoc` document, a removed `src` a fresh `about:blank`, `data:` and `blob:` URLs are loaded by Dommy itself, and any other URL goes to the window's navigation delegate's new optional `load_frame(frame, url:, ...)`. Only the latest navigation completes; the iframe's trusted `load` fires when it does. A `src` that an ancestor already shows (`<iframe src="">`-style recursion) is not loaded.
- `Dommy::Browser` loads iframes through its resources (for every browser that has resources, not only `navigable: true` ones); a URL nothing serves shows an empty error page with an opaque origin and still fires `load`, and a response of any status (404, 500) is shown as the frame's document.
- `Dommy::Rack::Session.new(app, javascript: true, load_frames: true)` loads a page's iframes from the app (one request per frame, before the page's `load`); without the option frames stay at about:blank and `within_frame` fetches on demand, as before.
- `loading="lazy"` iframes load after their document's `load` event (Dommy has no viewport to intersect) and do not delay it; changing `loading` to `eager` loads one at once, and another navigation of the frame cancels the pending lazy load.
- A link whose `target` (or `<base target>`) names an existing navigable — an iframe's name, `_parent`, `_top` — navigates that navigable instead of the link's own window.
- `Dommy::CookieJar`: one cookie store per browsing session with RFC 6265bis's storage model and cookie-string — Expires / Max-Age (capped at 400 days; a past date deletes: `"a=; expires=Thu, 01 Jan 1970 00:00:00 GMT"`), Domain (must domain-match the host; a single label is refused), Path (default-path of the URL), Secure (only from https, wss or a loopback host), HttpOnly (refused from and hidden from `document.cookie` / `cookieStore`), SameSite (`None` needs `Secure`), the `__Secure-` / `__Host-` prefixes, a 4096-octet name+value limit and 1024-octet attribute limit, and a string with a control character (`"b=A\0Z"`) ignored whole. Cookies are sent longest path first, then oldest.
- `Window#cookie_jar` (a frame uses its container's): `document.cookie` and `cookieStore` read and write it for the document's URL. `Dommy::Browser#cookie_jar` is shared by every page it shows, its navigations (each redirect hop sends `Cookie` and stores `Set-Cookie`) and its pages' `fetch` / XHR (credentials mode `include`, or `same-origin` to the page's own origin). `Dommy::Rack::CookieJar` is now that jar (same `store_from_header` / `cookies_for` / `set!` / `export` / `import!` API), and the session's pages read and write it: `document.cookie` after a response's `Set-Cookie: sid=42` is `"sid=42"`, and a cookie a page writes goes out with the next request.
- `Dommy::Browser` answers `window.open` with a new top-level browsing context: `window.open("/p")` (or `_blank`, or a name no window has) returns a real Window — its `opener` the window that opened it, its first document the initial about:blank with the opener's origin, its name the target — navigated to the URL from a task (firing `load` at it), sharing the browser's storage and cookies, and listed in `Dommy::Browser#popups`. `window.open("", "name")` finds a popup by name again, `noopener` returns null, `popup.opener = null` disowns, and `popup.close()` closes it (`closed` turns true at once; it leaves `#popups`). A window a script opened is script-closable whatever its history length. A navigation delegate may answer `find_window(name)` to expose its other top-level windows to `window.open` targets.
- `window.open`'s `features` are tokenized as HTML says, with `noopener` / `noreferrer` parsed as boolean features: `"=NOOPENER"`, `"noopener=yes"` and `"a=1, noreferrer"` mean no opener (null is returned), `"noopener=0"` and `"-noopener"` do not.
- Customized built-in elements: `customElements.define("my-button", class extends HTMLButtonElement {}, { extends: "button" })` with `document.createElement("button", { is: "my-button" })`, `new MyButton()`, `<button is="my-button">` in parsed markup, and `cloneNode()` all produce a `MyButton`.
- `ElementInternals`: `this.attachInternals()` in a custom element gives `internals.states` (a `CustomStateSet`, matched by the `:state(open)` selector), `internals.shadowRoot` (even when closed) and the default ARIA semantics (`internals.role = "button"`).
- Form-associated custom elements (`static formAssociated = true`): `internals.setFormValue(value)` submits with the form and shows up in `new FormData(form)`, `setValidity()` / `checkValidity()` / `validity` / `validationMessage` / `willValidate` take part in form validation, the element is listed in `form.elements` and can be disabled by `disabled` or a disabled `<fieldset>`, and `formAssociatedCallback(form)`, `formDisabledCallback(disabled)` and `formResetCallback()` run.
- Scoped custom element registries: `new CustomElementRegistry()`, `document.createElement("x-a", { customElementRegistry })`, `host.attachShadow({ mode: "open", customElementRegistry })` (elements parsed by that shadow root's `innerHTML` use it), `registry.initialize(root)`, `importNode(node, { customElementRegistry })`, and `element.customElementRegistry` / `shadowRoot.customElementRegistry` / `document.customElementRegistry`. The same class can be defined in several registries.
- User activation (HTML §6.4): a driver click (its `pointerdown` / `mousedown`) or key press (any `keydown` but Esc) gives the window sticky and transient activation, which lasts 5 seconds of virtual time; `navigator.userActivation.hasBeenActive` / `.isActive` report it, and the activation reaches the window's ancestor and same-origin descendant frames.
- `CloseWatcher` (HTML §6.9): `new CloseWatcher({signal})`, `requestClose()` / `close()` / `destroy()`, `oncancel` / `onclose`, with the window's close watcher manager grouping watchers created without user activation, so one close request closes the whole group and `cancel` can only be canceled after an activation.
- Light dismiss: a driver click outside an open `popover="auto"` (or hint) popover hides it before `pointerup` is dispatched, and clicking outside a modal `<dialog closedby="any">` (its backdrop) requests to close it. Clicking an element made inert by a modal dialog now sends the pointer events to the dialog, as a hit on its `::backdrop`.

### Changed

- The module sources kept for the next page are capped at 64 MB (`ModulePreload.max_source_bytes`), the least recently read going first, and one is used only for a URL the page's resources would serve, so a host the embedder blocks stays blocked.
- `childNodes` and `children` count and index a node's children through makiri without building the child list, as do `firstChild`, `lastChild`, `firstElementChild`, `lastElementChild` and `childElementCount`, and `isConnected` and `getRootNode()` ask makiri for the root: on a list of 4,000 children `firstChild` and `lastChild` take 0.2 µs instead of 56 µs, `childNodes.length` after a change 14 µs instead of 73 µs, and `isConnected` 31 levels deep 0.25 µs instead of 1.6 µs.
- A URL parsed from the same strings again (input, base and encoding, each up to 2 KB) is answered from the last 1,024 parses, as a copy the caller can change: dommy-examples' signup browser specs spend 11.5 ms parsing 1,206 URLs instead of 66 ms.
- A page's ES modules whose URL carries a content digest (`application-f004202c.js`) are kept for the rest of the process by default: the next page reads them without a request, and the big ones as bytecode. dommy-examples' signup browser specs make 88 requests instead of 292 and boot a page's scripts in 6.8 ms instead of 19.4 ms. `Dommy::Js::ModulePreload.scope = :all` keeps modules without a digest too, and `:none` keeps none; `ModulePreload.enabled` is gone.
- A CSS rule whose subject is only an attribute selector (`[type=checkbox]`, `[data-state] .x`) is matched only against elements carrying that attribute, so an element on a decidim page is run through 37 rules instead of 77 and the computed style of an element 21 levels deep takes 9.2 ms instead of 10.7 ms.
- A `<form>` builds the name and id table its named getter reads once per DOM change rather than on every property read, so reading `form.action` from script with 50 controls takes 27 µs instead of 222 µs.
- Requires makiri >= 0.16.0, for its child-list counts and indexes, `root_node`, and its refusal of a native extension built for another Ruby or makiri version.
- A CSS rule that needs an ancestor (`.menu li a`, `:where(.space-y-4 > :not(:last-child))`) is skipped without matching for an element whose ancestors lack it, so the computed style of an element 21 levels deep under decidim's 3,000-rule sheet takes 18.6 ms instead of 50.6 ms.
- A DOM edit keeps the document's CSS rule index unless it changed a stylesheet, the viewport, or something an `@scope`, shadow-tree or `::part` rule was matched against, so `getComputedStyle` after an edit on a page with decidim's 3,000-rule sheet takes 7.9 ms instead of 46 ms. An `@import`ed sheet is read once for the same parent sheets.
- A `<link>` stylesheet a page loads again is built from the split of its text kept from the last load, and the cascade reads its source until the CSSOM changes it: a page with decidim's 3,000-rule sheet gets it in 1.4 ms instead of 113 ms.
- `attachShadow()` on a host whose shadow root came from a declarative template of the same mode empties that shadow root (one removal per child) and returns it, instead of throwing `NotSupportedError`; a second call, or a different mode, still throws. The init dictionary is converted before anything else, so a missing `mode` or an unknown `slotAssignment` is a `TypeError` even on an element that cannot host a shadow root.
- Every string a script hands an operation, a constructor, a static operation or an attribute setter is converted as WebIDL declares it — DOMString, USVString or ByteString, nullable, `[LegacyNullToEmptyString]`, optional, variadic — in one place, before it reaches Ruby. The conversions are generated from the specs' own IDL into `lib/dommy/js/webidl_signatures.js` (`rake webidl:signatures`), replacing the hand-kept lists of null-to-empty setters and DOMString arguments. So `el.title = {toString() { return "t" }}` is `"t"` instead of a Ruby inspect string, `new URL("y", location)` resolves against the location, `params.set(obj, obj)` and `headers.set(obj, obj)` call `toString`, `el.id = Symbol()` and `params.append(Symbol(), "v")` throw `TypeError`, `el.id = null` is `"null"`, `new Headers().append("x", "\u0100")` throws `TypeError`, and a toString that throws stops the operation before it does anything.

- A call with fewer arguments than the IDL requires throws `TypeError` (`URL.parse()`, `params.append("x")`, `el.setAttribute("a")`, `document.createElement()`), checked by the same generated table, and `URL.parse.length` and the other static operations' `length` are the IDL's.
- An operation or attribute on an interface prototype checks its receiver: `URL.prototype.href` or `URL.prototype.toJSON.call({})` throws `TypeError` instead of calling the host with no object.
- Event handlers follow HTML's model: an `on*` handler's listener is added when it is first set and keeps its place in the listener list when its value changes (`el.onclick = a; el.addEventListener("click", b); el.onclick = c` runs `c` before `b`), and setting it to `null` removes it. An `onclick="…"` attribute is compiled when the handler is first read or run, into `function onclick(event) {…}` with the element, its form owner and the document in scope; a body that does not parse makes `el.onclick` `null` and reports a `SyntaxError` at the window, without losing the handler's place. The attribute steps run for `setAttribute` from Ruby too, and `removeAttribute("onclick")` removes only a handler that came from the attribute.
- A dynamically inserted `<script src>` runs in a task once fetched rather than at the next microtask checkpoint, so a microtask queued by the script that inserted it runs first (and does not see the new script as `document.currentScript`). One written by `document.write` still runs as soon as the writing script returns.
- `history.back()`, `history.forward()` and `history.go(n)` return before the traversal happens; `popstate` (and, when the fragment changes, `hashchange`) fire from a later task, so `history.back(); location.href` still reads the old URL. `history.go(0)` and `history.go()` reload. A traversal past the document's own entries goes to the navigation delegate's `traverse`. Ruby's `Dommy::Browser#back` / `#forward` still traverse immediately; `Dommy::Browser#traverse(delta)` is now the page-initiated form, performed at the next settle.
- Fragment navigations — `location.hash = "x"`, `location.href = "#x"`, `location.assign("#x")`, `location.replace("#x")` and clicking `<a href="#x">` — add a session history entry (`replace` replaces it), fire a trusted `popstate` at once and queue a trusted `hashchange` as a task; `history.length` grows by one for each. A navigation to the document's own URL, and a script navigation made while the document is still loading, replace the current entry.
- `location.protocol`, `host`, `hostname`, `port`, `pathname` and `search` assignments navigate to the modified URL (through the navigation delegate), as `location.href =` does: `location.search = "q=1"` loads `?q=1`. `location.protocol = "1x"` throws `SyntaxError`, and a protocol other than http(s) does nothing.
- `location.href = "/p"` from `/p#x` is a cross-document navigation (dropping the fragment is not a fragment navigation), and a relative URL given to `location` resolves against the document's base URL (`<base href>`).
- `pushState(data, "", url)` serializes `data` before looking at `url`, so a function throws `DataCloneError` even with a bad URL; an empty-string `url` keeps the document's URL including its fragment; the URL may differ from the document's only as HTML allows (any path/query/fragment for http(s), query/fragment for file:, the fragment otherwise; a different port, user or password is a `SecurityError`).
- `history.state` is the same object on every read until the active entry changes.
- `history.length`, `state`, `scrollRestoration`, `pushState`, `back` and the rest throw `SecurityError` once the document is not fully active (a removed frame's window, a page navigated away from).
- `history.length` reports the joint session history of `Dommy::Browser` and `Dommy::Rack::Session` (every page of the tab), not only the current document's entries. A navigation delegate opts in by answering `history_length`.
- The `load` event at the window is trusted and its `target` is the document.
- `pagehide` before `unload` is a `PageTransitionEvent`, and both are trusted and targeted at the document.
- `structuredClone(fn)` and `structuredClone({f() {}})` throw `DataCloneError`.
- `navigator.vendor` is `""` (it was `"Dommy"`, which HTML does not allow), and `navigator.languages` is a frozen array, the same object on every read.
- `location.origin` is the serialization of the URL's origin: `"null"` for `about:blank`, data: and file: pages. A frame's `about:blank` (or `about:srcdoc`) document has its creator's origin, so its `window.origin` and `document.domain` are the parent page's.
- `document.domain = value` checks its argument: a value that is neither the current domain nor a registrable suffix of it, an IP address, or a document with an opaque origin or no browsing context throw `SecurityError`; an accepted value becomes `document.domain`. (A single label stands in for a public suffix, so `"com"` is refused.)
- `localStorage` / `sessionStorage` of a document with an opaque origin (a data: page) throw `SecurityError`.
- `HTMLAnchorElement#hash` / `HTMLAreaElement#hash` (the URL fragment) are now `url_hash` / `url_hash=` in Ruby, so `Object#hash` is no longer overridden and anchors work as Hash keys, in a Set and with `uniq` (`[a, b].uniq` raised `TypeError`). JavaScript still reads and writes `a.hash`.
- Every interface prototype carries the IDL's attributes and operations that Dommy implements, generated from the specs' IDL (`lib/dommy/js/webidl_members.js`, `rake webidl:members`): `"popover" in HTMLElement.prototype`, `"showModal" in HTMLDialogElement.prototype` and `"loading" in HTMLImageElement.prototype` are true, so feature detection no longer installs polyfills over Dommy's own behaviour; a prototype member called on another object throws `TypeError`.
- The named-property behaviour of legacy platform objects (enumerable, writable, `[LegacyOverrideBuiltIns]`) is generated from the IDL too, which gives `document` its named properties as specified: `<img name=logo>` is `document.logo` and an own property, and a named element overrides a builtin (`<form name=body>` makes `document.body` that form, as in browsers).
- HTML attribute reflection is now generated from the specs' own IDL: every `[Reflect]` / `[ReflectURL]` / `[ReflectSetter]` / `[ReflectNonNegative]` / `[ReflectPositive]` / `[ReflectPositiveWithFallback]` attribute (with `[ReflectDefault]` / `[ReflectRange]`) is declared on its element class unless the class declares it itself, so the obsolete attributes HTML §16 still reflects now work: `table.cellPadding`, `table.bgColor`, `td.noWrap`, `td.ch` (`char`), `tr.vAlign`, `body.aLink` / `link` / `vLink` / `text` / `background`, `a.coords` / `shape` / `rev` / `charset` / `name`, `area.noHref`, `img.hspace` / `vspace` / `lowsrc`, `iframe.frameBorder` / `longDesc` / `scrolling`, `frame.*`, `frameset.cols` / `rows`, `object.codeBase` / `declare` / `standby`, `hr.noShade` / `size` / `color`, `br.clear`, `pre.width`, `html.version`, `ol` / `ul` / `dl` / `dir` `compact`, `link.charset` / `rev` / `target` / `imageSrcset` / `imageSizes`, `script.charset` / `event`, `param.type` / `valueType`, `embed.name` / `align`, and the `align` of div, p, h1–h6, caption, legend and the table parts. They also appear on the interface prototypes (`"bgColor" in HTMLBodyElement.prototype`).
- `details.open` is a plain boolean reflection visible to feature detection (`Object.getOwnPropertyDescriptor(HTMLDetailsElement.prototype, "open")`).
- `textarea.rows` / `cols` (`[ReflectPositiveWithFallback]`, defaults 2 and 20), `input.maxLength` / `minLength` and `textarea.maxLength` / `minLength` (`[ReflectNonNegative]`) and `progress.max` (`[ReflectPositive, ReflectDefault=1.0]`) are declared from the IDL rather than hand-written, with unchanged behaviour.
- The ARIA reflections on `Element` (`ariaLabel`, `ariaActiveDescendantElement`, `ariaLabelledByElements`, …) are read from the IDL and now sit on `Element.prototype` (`"ariaLabel" in Element.prototype` is true).
- New `HTMLMenuElement` (`<menu>`, with `compact`) and `HTMLMarqueeElement` (`<marquee>`: `behavior`, `direction`, `scrollAmount` (default 6), `scrollDelay` (default 85), `trueSpeed`, `hspace` / `vspace`, `width` / `height`, `bgColor`, `loop` — −1 unless the attribute is at least 1, and setting a value other than −1 or a positive number is ignored — and `start()` / `stop()`). Both elements used to be `HTMLUnknownElement`.
- `document.fgColor` / `linkColor` / `vlinkColor` / `alinkColor` / `bgColor` reflect the body element's `text` / `link` / `vlink` / `alink` / `bgcolor` attributes (`document.bgColor = "red"` sets `<body bgcolor="red">`; `null` writes `""`); with no body element, or a `frameset`, they read `""` and ignore writes.
- Which `on…` names are event handlers is generated from the specs' IDL (`rake webidl:event_handlers`, into `lib/dommy/js/webidl_event_handlers.js` and `lib/dommy/internal/event_handler_tables.rb`), replacing four hand-kept lists. A name is an event handler only on an object whose interface declares it: `div.onbogus = f` is an ordinary property that no `bogus` event runs, `"onbogus" in div` and `"onClick" in div` are false, `xhr.onfoo = f` is an expando, `"onreadystatechange" in div` is false while `"onreadystatechange" in document` is true, and an element in no HTML/SVG/MathML namespace has no `onclick`. `onfocusin`, `onfocusout` and `onpointerlockchange`, which no spec in the IDL declares, are no longer handlers.
- `structuredClone()`, `postMessage()` (window, MessagePort, BroadcastChannel, Worker) and `history.pushState`/`replaceState` serialize in the JS realm, as HTML's StructuredSerialize: cycles and shared references survive (`const o = {}; o.self = o; structuredClone(o).self` is the clone), and so do `BigInt`s, `new String("x")` and the other wrapper objects, a RegExp's source and flags, typed arrays and `DataView`s (with their `ArrayBuffer` shared between views), resizable `ArrayBuffer`s and length-tracking views, `Map`/`Set`, `Error` types with `message`, `stack` and `cause`, and lone surrogates in strings. Functions, symbols, DOM nodes, windows, `WeakMap`s and promises throw a `DataCloneError` DOMException; `Blob`, `File`, `FileList`, `ImageData`, `DOMException` and `DOMRect` are cloned as new objects.
- A transfer list is honoured: `structuredClone(buf, {transfer: [buf]})` and `port.postMessage(msg, [buf])` detach the `ArrayBuffer` (`buf.byteLength` is 0), transferring a `MessagePort` hands the receiver a new port entangled with the other end (its queued messages follow it), and a duplicate, detached or non-transferable item throws `DataCloneError`.
- `window.postMessage(message, targetOrigin, transfer)` and `postMessage(message, {targetOrigin, transfer})`: `targetOrigin` `"/"` is the poster's own origin, `"*"` anyone, anything else must parse as a URL (`"http://foo bar"` throws `SyntaxError`), and a message for another origin is dropped; the `message` event has `origin`, `source` and a frozen `ports` array, and `isTrusted` is true.
- `MessagePort`s queue messages until `start()` (or an `onmessage` assignment) and then deliver them one task each, in order; `close()` disentangles both ends; a port posting itself in its transfer list throws `DataCloneError`. `BroadcastChannel#postMessage` on a closed channel throws `InvalidStateError`, and its `message` event carries the sender's `origin`.
- Promises returned by host APIs (`fetch()`, `blob.text()`, `img.decode()`, `media.play()`, clipboard reads, …) are the page's own `Promise` objects: `fetch(url) instanceof Promise`, `Object.prototype.toString.call(p)` is `"[object Promise]"` and `Promise.resolve(p) === p`.
- `String(element)` is `"[object HTMLDivElement]"` (Object.prototype.toString), not the element's HTML; `<a>` and `<area>` keep their `href` stringifier. `String(el.style)` is `"[object CSSStyleDeclaration]"` instead of throwing, and `el.style.toString` / `valueOf` are Object.prototype's.
- `DOMException` inherits from `Error.prototype`: `new DOMException("m", "SyntaxError") instanceof Error` and `String(e)` is `"SyntaxError: m"`.
- The event handler IDL attributes of `XMLHttpRequest`, `XMLHttpRequestUpload`, `FileReader`, `EventSource`, `WebSocket`, `Worker`, `MessagePort`, `BroadcastChannel`, `AbortSignal`, `Notification` and `MediaQueryList` are the ones their IDL declares: `xhr.upload.onprogress`, `port.onmessageerror` and `channel.onmessageerror` work, a non-function value reads back as `null`, the handler keeps its place in the listener list, and `"onfoo" in xhr` / `"onclick" in new EventTarget()` are false.
- The window's event handlers are bare globals: `onmessage = e => …` (and `onload`, `onerror`, …) at the top level of a script sets `window.onmessage`.
- `unhandledrejection` fires from a task queued at the end of the microtask checkpoint, for the promises still unhandled when that task runs: a `.catch()` attached one task later keeps the page silent, tasks queued earlier run first, a promise its own `unhandledrejection` listener handles gets no `rejectionhandled`, and `rejectionhandled` is fired from a queued task.
- `new MessageEvent("message", {data: false}).data` is `false` (it was `null`).
- A JS-defined custom element reports the interface it derives from: `Object.prototype.toString.call(el)` is `[object HTMLElement]` and inherited prototype members accept it (`el.title = "x"`, `el.ariaAtomic = "true"` no longer throw "Illegal invocation").
- Custom element reactions follow HTML's element queues: callbacks run when the `[CEReactions]` member that caused them returns (`el.setAttribute(...)`, `parent.appendChild(el)`), element by element in the order they were enqueued, or from the backup element queue in a microtask for mutations made outside one. A reaction enqueued while another is running no longer runs re-entrantly in the middle of it.
- JS-defined custom elements are constructed when they are created or upgraded, not lazily when the node first reaches JS: `customElements.define()` upgrades the document's matching elements (constructor, then `attributeChangedCallback` for each existing attribute, then `connectedCallback`) before it returns, and `div.innerHTML = "<my-el>"` / `cloneNode()` / `importNode()` upgrade the elements they create.
- `connectedCallback` / `disconnectedCallback` run only when an element actually becomes connected or disconnected (inserting into a detached shadow tree no longer connects it), and moving a custom element into another document runs `disconnectedCallback`, `adoptedCallback(oldDocument, newDocument)` and `connectedCallback`.
- `document.createElement("my-el")` checks what the constructor returned (an `HTMLElement`, no attributes or children, no parent, this document, the right local name); on a failure, or when the constructor throws, the exception is reported and the result is an `HTMLUnknownElement` that does not match `:defined`.
- Lifecycle callbacks and `observedAttributes` are read once, at `define()` time; each definition has its own construction stack (constructing another instance before `super()` throws a `TypeError`); `define()` with a non-constructor (an arrow function) throws a `TypeError` without touching it.
- Every window has its own `customElements` registry, `iframe.contentWindow.customElements` included, and the bare `customElements` is `window.customElements`.
- `define(name, ctor, { extends })` throws `NotSupportedError` when `extends` is a valid custom element name or not an HTML element.
- Custom element names follow the current HTML rule: any valid element local name that starts with a lowercase ASCII letter, has no uppercase ASCII letters and contains a `-` (so `a-a×` is valid).
- `document.open()` / `write()` / `close()` throw an `InvalidStateError` while a script-created parser runs custom element constructors and reactions.
- The events the driver fires for the user's input (`click`, `send_keys`, `fill_in`, `ime_input`, `right_click`, …) are now trusted: `event.isTrusted` is `true` in their listeners, while events a script constructs and dispatches stay untrusted.
- Activation-gated APIs follow it: `input.showPicker()` / `select.showPicker()` throw `NotAllowedError` without transient activation and consume it otherwise; `element.requestFullscreen()` rejects (and fires `fullscreenerror`) without transient activation and consumes it otherwise; `window.open()` of a new window consumes it.
- Esc from the driver (`send_keys :escape`) is a close request: unless its `keydown` is canceled, it closes the topmost modal dialog (firing `cancel` then `close`), `closedby="any"`/`"closerequest"` dialog, auto popover or `CloseWatcher`. Dialogs and popovers now establish their close watchers through the same manager, so `dialog.requestClose()` and Esc share one model.
- Tab / Shift+Tab move the focus by HTML's sequential focus navigation: `send_keys :tab` and `send_keys [:shift, :tab]` go through positive `tabindex` values first, then tree order, entering shadow trees and slots in place, visiting a popover's contents right after its invoker, skipping disabled, inert and unrendered elements, keeping the focus inside a modal dialog, and wrapping around at either end. A click on non-focusable content sets the navigation starting point. `send_keys` takes chords such as `[:shift, :tab]` or `[:control, "a"]`.
- capybara-dommy: session-level `send_keys` (e.g. `page.send_keys(:tab)`) dispatches real key events to the focused element under JavaScript, and Tab without JavaScript uses the same sequential navigation order.
- `:focus-visible` now matches only when the focus is indicated: focus moved by Tab or by a key-driven script, a clicked text field or editing host, script focus with no pointer interaction before it, or `element.focus({focusVisible: true})` — not a button or `tabindex` element focused by a click, nor script focus right after one (`focus({focusVisible: false})` never indicates it).
- A driver right click fires `contextmenu` on the press (before `pointerup` / `mouseup`) and ends with `auxclick`; Enter fires `keypress` before its default action; Space activates a focused button with a trusted click.
- The user agent style sheet now applies inside shadow trees (a `<p>` in a shadow root is `display: block`, a closed `<dialog>` there is `display: none`), and `slot` is `display: contents`, so a slot is never focusable, even with a `tabindex`.
- Enter on a focused button, link or button-type input activates it (a trusted `click`), as in a browser.
- A srcless (or `about:blank`) iframe fires its `load` synchronously during the insertion, as HTML's "process the iframe attributes" says (`document.body.appendChild(iframe)` has fired it by the time it returns); it used to fire from a microtask. A `srcdoc` iframe is navigated from a task (its document is `about:blank` right after insertion).
- Removing an iframe destroys its child navigable: `contentWindow` / `contentDocument` become null and the old window is `closed`; inserting it again creates a new one.
- `iframe.contentDocument` from script is null when the frame's document is not same origin with the iframe's document (a `data:` page, an error page, another origin).
- A frame navigated from its initial about:blank to a same-origin document keeps its Window, so a `contentWindow` read before the load is still the frame's window afterwards.
- Script boot runs HTML's "the end": the document turns `interactive` before deferred and module scripts run, and `DOMContentLoaded` and then `load` / `pageshow` fire from tasks of their own — after work the page queued before them, such as a `setTimeout(f, 0)`, a `history.go(-1)` or an iframe's navigation (the load event waits for child frames still navigating). Boot runs those tasks before it returns, so a booted page (`Dommy::Browser`, `Dommy::Rack::Session#visit`) is still loaded when it returns; a later timer stays pending.
- `document.cookie` follows HTML: a cookie-averse document (no browsing context — `createHTMLDocument`, `DOMParser` — or a URL that is not http(s), such as an about:blank frame) reads `""` and ignores writes, and a document with an opaque origin throws `SecurityError`. It used to keep a name=value map per document, so cookies were neither shared with requests nor between pages.
- `cookieStore` uses the same jar as `document.cookie`: `get` / `getAll` see the cookies for the document's URL (with their domain, path, expiry, secure and sameSite), `set` stores a `Secure`, `Path=/`, `SameSite=Strict` cookie by default (a refused one rejects with `TypeError`), and `delete` expires it.
- A redirect whose `Location` is not an http(s) URL is a network error for `Dommy::Browser`'s navigations, and a navigation's final URL is the request URL unless the resources adapter reports that it followed a redirect.

### Fixed

- The CSS layer no longer falls back when makiri's CSS parser is missing: `getComputedStyle` answered with the inline style, the cascade treated the page as unstyled, and `innerText` and accessible names skipped computed styles, which hid a broken makiri. makiri is a hard dependency; `Internal::CSS::Parser.available?` and `Parser::Unavailable` are gone.
- Boolean arguments and init members are read with JavaScript's ToBoolean, so `0`, `""` and `null` are false: `cloneNode("")` and `cloneNode(undefined)` clone shallow, `toggleAttribute(name, 0)` and `classList.toggle(token, null)` force removal (a missing or undefined force still toggles), `range.collapse(0)` collapses to the end, and `new Event(type, {bubbles: 0})` does not bubble. `importNode(node, null)` clones deep, as null converts to the options dictionary; a missing or undefined options argument still clones shallow.
- Setting `data`, `nodeValue` or `textContent` on a Text, Comment or ProcessingInstruction from script replaces the data as the Ruby setter does, so a live range inside the node moves to its start instead of being left past its end.
- An `unsigned long` or `unsigned short` argument (CharacterData's offsets and counts, Range's offsets, `compareBoundaryPoints`' `how`) converts through JavaScript's ToNumber: `true` is 1, `[2]` is 2, `"0b11"` and `"0o7"` are 3 and 7, `"1_0"` and `"-0x1"` are NaN and so 0, and white space such as U+00A0, U+3000 and U+FEFF around a number is trimmed.
- `compareDocumentPosition`, `insertBefore`, `MutationObserver#observe`, `setAttributeNode` and `setAttributeNodeNS` throw a `TypeError` for an argument that is not a `Node` (or an `Attr`) as WebIDL converts it, also when called from Ruby: `compareDocumentPosition(null)`, `insertBefore(node, "x")`, `observe(true, ...)` and `setAttributeNode(null)`.
- `MutationObserver#observe` converts `attributeFilter` as a `sequence<DOMString>`: a value that is not an array (`null`, a string, a plain object) throws a `TypeError`, each name goes through JavaScript's ToString (`null` is `"null"`, `1.0` is `"1"`), and the names are matched case-sensitively, so `["ID"]` no longer matches an `id` attribute. An `undefined` member counts as missing.
- `addEventListener`'s `once` member is read with JavaScript truthiness, so `{once: 0}` and `{once: ""}` add an ordinary listener, and a `signal` member that is not an `AbortSignal` (`null` included) throws a `TypeError` before anything is added.
- `append`, `prepend`, `replaceChildren`, `before`, `after` and `replaceWith` with two or more arguments convert them into a node first, as DOM says: they are moved into a new DocumentFragment before the insertion is checked, so `el.after(a, b)` that the parent rejects leaves `a` and `b` in that fragment, and `x.before(a, doctype)` leaves `a` there, instead of rejecting the call with nothing moved.
- `setAttribute`, `getAttribute`, `hasAttribute`, attribute selectors and the CSS cascade fold an HTML element's attribute and tag names in ASCII only, as DOM says: `setAttribute("Ö", "")` makes an attribute named `Ö`, and `[Ä]` matches the `Ä` attribute the parser keeps.
- Upgrading a custom element is a selector-visible change: a rule on `x-foo:defined` reaches the element and its descendants once `customElements.define` upgrades it, and a cached `querySelectorAll(":defined")` is recomputed.
- `createElement("Foo:Bar")` in a page parsed as HTML and typed as XHTML or XML makes an element whose local name is `Foo:Bar`, in the namespace of that type's `createElement` (the HTML namespace for XHTML, none for XML).
- An `<iframe>` showing a text response (`text/plain`, CSS, JavaScript, JSON) has a document whose `contentType` is that type and whose `compatMode` is `"BackCompat"`.
- A shadow tree's `:host` rule matches the host only when its whole compound does: the host is featureless there (CSS Scoping), so `:host.dark` or `:host[x]` never match it, and `:host:has(...)` looks at the shadow tree, never the light-DOM children (a sibling relation never holds). `:host:has(.x)` used to style every host.
- `new EventSource(url)` from script works again. The mixin that gives `ToggleEvent` and `CommandEvent` their `source` was named `Dommy::Internal::EventSource`, which the window's constructor table found instead of `Dommy::EventSource` ("undefined method `new' for module Dommy::Internal::EventSource"), so no page could open a Server-Sent Events stream (Turbo's `<turbo-stream-source>` among them). The mixin is now `Internal::SourceMember`.
- The promise `__rbHost.makeHostDeferred()` hands to script comes back from the host as itself: rejected or fulfilled with as a value, it had been turned into a realm Promise standing for the same host promise, so `reason === promise` failed (Promises/A+ 2.3.3.3.2 timed out in the engine gems' runs of the official suite). Every other host promise still crosses as a realm Promise.
- `shadowRoot.innerHTML` in an XML document is the XML serialization, like an element's.
- An HTML element gets the interface HTML's "element interface" gives its name: `b`, `section`, `article`, `nav`, `summary` and the other elements without an interface of their own (and `acronym`, `center`, `tt`, …) are `HTMLElement` instead of `HTMLUnknownElement`, `listing` and `xmp` are `HTMLPreElement`, and `applet`, `blink`, `keygen` and the like stay `HTMLUnknownElement`.
- `DOMParser#parseFromString` follows the spec's steps: from script `type` is required and matched exactly (`"TEXT/HTML"` throws `TypeError`; the Ruby API keeps its `"text/html"` default), an XML parse error — empty input included — returns a document whose root is a `<parsererror>` in the Mozilla namespace instead of raising, and the new document takes the creating document's URL and origin (so `domain` too), as `createDocument` / `createHTMLDocument` documents take its origin.
- `URL.prototype` has `href`, `toJSON` and the URL's other members, and `URLSearchParams.prototype` has `append`, `get`, `size` and the rest, so `"append" in URLSearchParams.prototype` is true and `URLSearchParams.prototype.append.call(params, …)` works.
- URLSearchParams, FormData and Headers are WebIDL pair iterables: `@@iterator` is the `entries` function itself, their iterators inherit from `%IteratorPrototype%` (so iterator helpers work) and are `[object URLSearchParams Iterator]`, and `forEach` passes its `thisArg` and throws `TypeError` for a non-callable callback.
- `URL.createObjectURL` returns `blob:<origin>/<uuid>`, so `new URL(URL.createObjectURL(blob)).origin` is the page's origin rather than `"null"`, and throws `TypeError` for something that is not a Blob.
- A URLSearchParams has no `length`, and `"length" in el` is false for an object that has none; `window.length` is the number of child frames.
- An empty-string base is a base that fails to parse, not a missing one: `new URL("about:blank", "")` throws, and `URL.parse(url, "")` is null.
- `new URLSearchParams(init)` converts its argument as WebIDL's union of a sequence of sequences, a record and a string. An object whose `@@iterator` is undefined or null is a record — a function too, so `new URLSearchParams(DOMException)` reads its constants instead of stringifying the object — and a record key keeps a NUL (`{"a\0b": 1}` is the name `"a\0b"`, not `"a"`). A symbol record key, a non-callable `@@iterator` and a sequence element that is not an iterable object throw `TypeError`, and `null` or a number is the string it converts to (`new URLSearchParams(null)` is `"null="`).
- `DOMException.prototype` has `name`, `message` and `code` getters, and like every other prototype getter for a readonly attribute (`URL.prototype.origin`, `HTMLTemplateElement.prototype.content`, …) they throw `TypeError` on a receiver that does not implement the interface, instead of reading nothing from the host.
- `el.onclick = "code"` or `= 42` sets the handler to `null` (EventHandler is `[LegacyTreatNonObjectAsNull]`), `el.onclick = obj` reads back as the same `obj`, and a non-callable handler object is never asked for `handleEvent`.
- `<body onload="…">` and the other Window-reflecting body/frameset attributes are `window.onload` itself (one handler, read back through `window.onload`), and `<body onerror>` receives `(event, source, lineno, colno, error)`.
- The special `onerror` rules (five arguments, `return true` cancels) apply only to an `ErrorEvent` at the window; `onbeforeunload` returning a string cancels the event and sets `returnValue` when it is empty.
- `:defined` matches: every element but a custom-named HTML element that has not been defined and constructed (`document.createElement("a-a").matches(":defined")` is false until `customElements.define("a-a", …)`, and false inside its constructor).
- Events the browser fires are trusted (`event.isTrusted === true`): `load`, `DOMContentLoaded`, `readystatechange`, a script's `load`/`error`, the `error` event of a reported exception, `unhandledrejection` and `rejectionhandled`.
- `document.currentScript` is restored to its previous value after a script runs, so `document.currentScript` inside an outer script is the outer script again after it inserted and ran an inner one; it is the element for a dynamically inserted inline script too, `null` for a script in a shadow tree and for module scripts, and `window.onerror` for a throwing script sees the script as `currentScript`.
- A script's type follows HTML's rules: every JavaScript MIME type runs (`type="text/javascript1.5"`, `"text/jscript"`, `"application/x-javascript"`, `" text/javascript "`), a script with only `language="javascript1.2"` runs, and `type="text/javascript; charset=utf-8"` or `language="vbscript"` does not.
- An empty `<script>` (no `src`, no text) is not spent by being inserted: appending text to it, or setting its `src`, runs it. A whitespace-only script is not empty. Setting `src` on a connected script that never ran runs it.
- A classic script with `nomodule` does not run, and `<script event="onclick" for="window">` does not run (only `event="onload"`/`"onload()"` with `for="window"`).
- A parser-inserted `<script src>` fires `load` after it runs and `error` when the fetch fails (it used to fire neither); script `load`/`error` events are trusted, and an empty `src` fires `error`. `<script src="data:…">` runs.
- `window.onerror` for a throwing inserted script or a string timer handler (`setTimeout("throw new Error('x')")`) gets the Error that was thrown as its fifth argument.
- `window.setTimeout(fn, 0, "a", "b")` and `setInterval` pass the extra arguments to `fn` and call it with the window as `this`; a string handler runs as a classic script. (The bare `setTimeout` global, defined by dommy-js-quickjs, still drops them.)
- A timer's timeout converts as a WebIDL `long`: `setTimeout(fn, Infinity)` fires at once instead of raising `FloatDomainError`, and `2 ** 32 + 1` is 1 ms.
- `clearTimeout(id)` no longer cancels an animation frame or idle callback with the same number: `requestAnimationFrame` and `requestIdleCallback` number their handles separately from timers.
- `requestIdleCallback`'s callback gets an `IdleDeadline` with a `timeRemaining()` method and `didTimeout`, instead of a plain object.
- `history.pushState(...); history.back()` returns to the document's URL, not `http://localhost/`, when the embedder set the URL after the Window was built (`Dommy::Browser`, `Dommy::Rack::Session`, iframes).
- `Dommy::Browser` records `pushState` / `replaceState` / fragment entries in its joint history, so `browser.back` after a `pushState` pops the state instead of re-fetching the previous document.
- `canvas.width` / `canvas.height` reflect as `unsigned long` with defaults 300 and 150: `width="-1"`, `width="abc"` and a value past 2147483647 read `300` (they read `-1`, `0`, …), `" 12px"` reads `12`, and `canvas.height = 3000000000` writes `"150"`.
- `img.width = 2147483648` writes `"0"` and `img.width = -0` writes `"0"` from JavaScript too (the JS setter wrote the number's Ruby string, `"2147483648.0"`, `"-0"`); the IDL `unsigned long` conversion now applies to both.
- A `double` IDL attribute writes the number as JavaScript prints it: `meter.value = 1e25` stores `"1e+25"` (was `"10000000000000000905969664"`) and `meter.max = 1e-10` stores `"1e-10"` (was `"1.0e-10"`).
- `<meter>` and `<progress>` read their attributes with HTML's floating-point rules instead of Ruby's `Float()`: `value="0.5px"` is `0.5`, `max="\v7"` is not a number, `max="1_0"` is `1` and `max="0x10"` is `0`.
- A `<progress>` with a `value` attribute is determinate whatever the attribute says: `value=""` has `position` `0`, not `-1`. `progress.max = 8` writes `"8"` (and ignores a value that is not greater than zero) as `[ReflectPositive]` reflection does.
- `:lang()` inside a shadow tree follows the host's language (`<div lang=en-AU>`'s shadow `<b>` matches `:lang(en-AU)`), and an element no `lang` covers takes the document's `<meta http-equiv="content-language" content="fr-CA">` language (the first token; a value with a comma sets nothing; the pragma applies when the meta is inserted and stays after it is removed).
- A stringifier read off an object checks its receiver: `a.toString.call({})` and `el.classList.toString.call({})` throw `TypeError`, and `a.toString.call(otherA)` is the other anchor's `href` (it returned the first anchor's).
- `body.onload` and the other Window-reflecting handlers of a `body` or `frameset` in a document without a window (`document.implementation.createHTMLDocument()`) read as `null` and ignore assignments instead of becoming handlers of the element.

## 0.15.0 — 2026-10-04

### Added

- `accessKey`, `autocapitalize`, `autocorrect`, `autofocus`, `contentEditable`, `draggable`, `enterKeyHint`, `headingOffset`, `headingReset`, `inert`, `inputMode`, `isContentEditable`, `nonce`, `spellcheck`, `tabIndex`, `title` and `writingSuggestions` on HTML elements, and `nonce` on SVG elements.
- The ARIAMixin attributes are on `Element.prototype`, so `"ariaLabelledByElements" in Element.prototype` is true.
- An element in the MathML namespace is a `MathMLElement`, with `dataset`, `nonce`, `autofocus`, `tabIndex`, `style`, `focus()` and `blur()`.
- `Dommy::Js::ModulePreload.enabled = true` reads a page's ES modules of 10 KB or more as bytecode from the second page of the same origin on, with an engine that can preload them (dommy-js-quickjs on quickjs 0.22): a 400 KB module boots in about 9 ms instead of 30 ms. A preloaded module is not fetched again, so it is off by default for apps whose module URLs carry no digest.

### Changed

- `Dommy::Backend` is Makiri's adapter itself: `Backend.use`, `Backend.current` and `Dommy.backend` are gone, as is the `DOMMY_BACKEND` test switch, and each DOM call reaches Makiri without a dispatch in between.
- **Requires makiri >= 0.14.0.** Its queries no longer warn about chilled string literals under Ruby 4.0, it keeps a namespace URI's case, finds an attribute by namespace and local name, creates an element by the DOM's `createElementNS` in an XML document too, and counts the tree's and the attributes' edits (`tree_version`, `attribute_version`).
- `document.body` is the first `body` or `frameset` child of an HTML `html` document element, as HTML defines it: a `body` deeper in the tree, one in another namespace, or one under a non-HTML root element is not it, and a `frameset` is. `document.head` likewise needs an HTML `html` document element.
- `getElementsByName` returns a live `NodeList`, as HTML specifies, instead of an `HTMLCollection`; it has no `namedItem`.
- An element in no namespace, or in one other than HTML, SVG and MathML, is a plain `Element` without `dataset`, `style`, `tabIndex`, `focus()` and the rest HTML and CSSOM give only to those three: `createElementNS(null, "div").dataset` is undefined, and the Ruby object has no `dataset` method.
- `hidden`, `translate`, `popover`, `accessKeyLabel` and the `offset*` metrics are on HTML elements only, and `value` only on the elements whose interface has one: `div.value` is undefined.
- `click()`, `showPopover()`, `hidePopover()` and `togglePopover()` are on HTML elements only, and `meta.charset`, which no IDL defines, is gone; `meta.media` and `meta.scheme` reflect their attributes.
- `showPopover()` and `hidePopover()` throw `NotSupportedError` on an element without the `popover` attribute and `InvalidStateError` on a disconnected one or an open modal dialog, and `togglePopover(force)` takes its `force`.
- `hidden` is `"until-found"` for that state; setting it to `false`, `""`, `null`, `0` or `NaN` removes the attribute, and `hidden=until-found` is not `display: none`.
- `href` is on the SVG elements that refer to a resource only — `a`, `use`, `image`, the gradients and the like — and reads `xlink:href` when there is no `href`.
- `ariaLabelledByElements` and the other ARIA element lists are frozen arrays, the same object until their elements change, instead of live `NodeList`s.
- `el.ariaFoo`, `el.ariaLabelledBy` and any other name ARIAMixin does not define are ordinary properties: setting one writes no attribute.
- A `<script>` from `createContextualFragment` runs when the fragment is inserted.
- `removeNamedItem` and `removeNamedItemNS` throw `NotFoundError` when the element has no such attribute.
- A file input's files are set from Ruby with `input.files = [file]`, as `input.files = dt.files` sets them from script; `__driver_set_files__` is gone.
- `innerText` finds a table's last row and a row's last cell once rather than once per row and cell: a page with an 800-row table reads in 521 ms instead of 910 ms.
- `isConnected` takes about 1.1 µs instead of 2.7 µs, a computed style about 7% less when an element declares no custom property, and a node already wrapped is found in 150 ns instead of 198 ns.
- A loop over a live `childNodes` or `children` by index is linear: reading `length` and `item(i)` for 4,000 children of both lists takes 8 ms instead of 790 ms.
- `getRootNode` asks the shadow-root registry about a node's root alone rather than every ancestor, taking 1.6 µs instead of 5 µs, and `isConnected` and the shadow-root lookups do the same.
- A node already wrapped is found in 82 ns instead of 150 ns.
- `:nth-child` and `:nth-of-type` list a parent's children once rather than once per child: over 3,000 siblings, `querySelectorAll("p:nth-of-type(3n+1)")` takes 9 ms instead of 5.6 s.
- An element's `children` and `childNodes` lists are made when first read, so wrapping an element allocates 5 objects instead of 24.
- An `aria-labelledby` or `aria-describedby` reference in the document is resolved by its id lookup: accessible names for 2,400 labelled inputs take 0.8 s instead of 1.9 s.

### Fixed

- A boolean IDL attribute converts its value as JavaScript does: `el.disabled = 0`, `el.draggable = ""` and `el.translate = NaN` set the false state.
- `togglePopover` converts its argument as a boolean or a `{force}` dictionary: `togglePopover(1)` shows, `togglePopover(null)` toggles, and `togglePopover(true)` on a showing popover returns `true` without throwing.
- `:nth-child` and `:nth-of-type` count the children of a `DocumentFragment` or shadow root by their place: in a fragment of three `<i>`, `:nth-child(2)` matches the second.
- The `outerHTML` setter on a child of `html` parses in the `html` context, so `body.outerHTML = "<body class=x>hi</body>"` makes a `body` with its class.
- `createContextualFragment` makes the fragment in its context element's document, and with no context element parses in an HTML `body` in an XML document too.
- Setting a document's `content_type` decides its mode again: an `application/xhtml+xml` response without a doctype is `"CSS1Compat"`.
- `createElement` in a document parsed as HTML and typed as XHTML or XML keeps the name's case (`fooBar`), and `createElement("xmlns")` makes an HTML element.
- An invalid `autocapitalize` value, the empty one included, is `"sentences"`.
- `FormData` stores a `Blob` as a `File` named `"blob"` and names a file by the `filename` argument of `append` and `set`.
- `addEventListener` and `fetch` take only an `AbortSignal` as their `signal`.
- A style declaration answers `respond_to?` for CSS property names only, so it is never taken for a callback or an event listener.
- A host object passed where a callback is expected is not called as a function.
- `createDocumentType` in an XML document returns a doctype node that joins the tree, as in an HTML document.
- A `querySelector` result memoized by the document is retired by a child-list or attribute edit made on the backend node directly, not only by one made through the DOM.
- A namespace URI keeps its case: `createElementNS("fooNamespace", "e").namespaceURI` is `"fooNamespace"`, `getAttributeNS("attrNS", "x")` finds the attribute `setAttributeNS("attrNS", "a:x", v)` made, and an element in `HTTP://WWW.W3.ORG/1999/XHTML` is not an HTML element.
- `document.body = element` sets the body in HTML and XML documents alike: it replaces the current `body` or `frameset`, or is appended to the document element, and throws `HierarchyRequestError` for anything but a `body` or `frameset`.
- A document's element children skip its doctype: an element appended after the root element was removed is its `documentElement` and its only child element.
- `document.title` is the first `title` in the HTML namespace, or an SVG document's own `title` child, and reads only that element's own text, as a title element's `text` does.
- `insertAdjacentHTML`, the `outerHTML` setter and `createContextualFragment` parse in their context element: `<rect/>` inserted into an `<svg>` is an SVG element, and in an XML document `insertAdjacentHTML` parses XML.
- `attachShadow` takes only an HTML element whose local name, as written, may host a shadow root: a `div` in another namespace or a `DIV` from `createElementNS` throws `NotSupportedError`.
- `isContentEditable` and `:read-write` hold inside an editing host and in a document whose `designMode` is `"on"`, until a `contenteditable="false"`.
- `svg.tabIndex` is a number: `-1`, or `0` for an SVG `a`, without a `tabindex` attribute.
- `getElementById` compares ids case-sensitively in a quirks-mode document too: `<p id=Bar>` is not found by `"bar"`.
- In a quirks-mode document, id and class selectors match ASCII case-insensitively in `querySelector`, `matches` and the style cascade: `.foo` finds and styles `<p class=Foo>`.
- `document.compatMode` follows the HTML parser's mode: an XHTML 1.0 Strict or Transitional doctype with its system identifier is `"CSS1Compat"`, a cloned document keeps its original's mode, and removing the doctype later does not change it.
- `getElementById` and `getElementsByClassName` find an id or a class made of a space character such as U+00A0 or U+3000, where they raised a selector syntax error.
- `getElementsByClassName`, `getElementsByName` and `getElementById` take any value: a class like `1`, `a.b` or `[x]`, a name with a quote, and an id holding NUL are found. `getElementsByClassName` folds ASCII case in a quirks-mode document.
- `getElementsByName` returns HTML elements only: an `<svg name>` or a `<math name>` is not among them.
- An element's HTML attributes are the ones in no namespace: an `id`, `title`, `style` or `required` made with `setAttributeNS("urn:x", …)` does not count for `getElementById`, selectors, `el.title`, the inline style or `:required`, and setting a reflection writes the attribute in no namespace beside it.
- `:lang()` follows `xml:lang`, and `lang=""` matches no language.
- An ARIA reflection reads and writes its attribute in no namespace and resolves its IDREFs in the element's own tree, and any write to the attribute drops an element set through the reflection.
- The accessible name, description and role follow the elements set through `ariaLabelledByElements` and `ariaDescribedByElements` and the IDREFs in the element's own tree: a shadow tree's `aria-labelledby` does not name an element outside it.
- `adoptNode(attr)` returns the `Attr` and moves it into the document, leaving it on its element.
- An `Attr` keeps its node document when it is removed from its element, takes its element's document when appended to one, and moves with an adopted element.
- An `Attr` is outside the tree: its parent, children and siblings are null, its `childNodes` empty and `isConnected` false, and it answers `isEqualNode` and `contains`.
- `compareDocumentPosition` places an `Attr` at its element, before the element's children: an element contains its attributes, and two attributes of one element compare in attribute order.
- `removeAttributeNode`, `setAttributeNode` and `attr.value = …` act on the `Attr` they are given even when another attribute shares its qualified name.
- `removeAttributeNS` drops an ARIA element reference along with its `aria-*` attribute, as `removeAttribute` does.
- Upgrading a custom element passes each attribute's namespace to `attributeChangedCallback`.
- The canvas size, meter values, an input's step bounds and lengths, and the `on*` handler an element compiles on first dispatch read their attribute in no namespace too.
- `observedAttributes` matches an attribute's local name exactly: a `fooBar` made with `setAttributeNS` is observed as `"fooBar"`.
- A style attribute and a CSSOM declaration block are read in tokens: a `;` or `:` inside a string, a function, a `{}` block, an escape or an unquoted `url()` stays in its value, so `content: "a;b"`, `url(data:image/png;base64,…)` and `url(a/*b.png)` keep the declarations after them, and a comment hides nothing that follows it. The computed style reads the attribute the same way.
- A CR, a CRLF and an FF in a style attribute are each one newline, so a backslash before a CRLF in a string continues the string.
- A declaration's value with a `;`, a `!` or an unmatched closing bracket at its top level is dropped, so `setProperty("--x", "1; color: red")` adds nothing, and a bracket closes only a block of its own kind (`calc(1px]; color: red` is all one value).
- A custom property's value may be empty (`--x:;`, `--x: /* c */`) or hold a colon (`--time: 10:30`), through `setProperty` too.
- A `var()` inside a string or a comment is text: `content: "var(--x)"` is not substituted, and `content: "var(--"` is kept.
- `[*|att=v]` matches when any `att`, in any namespace, has the value; `[att]` looks only at the attribute in no namespace; the `i` flag folds ASCII case only, and `~=` splits on ASCII whitespace.
- An+B is read in tokens: `:nth-child(2n/**/+1)` and `:nth-child(2\6E+1)` parse.
- A selector argument list splits at commas outside escapes, strings and comments: `:is(.a\,b, c)` is two selectors.
- A comment may sit between the two delims of an attribute matcher or around a namespace `|` (`[a~/**/=x]`, `*|/**/p`), and the attribute modifier may be escaped (`[a=x \69]`).
- An escape past U+10FFFF or of a surrogate is U+FFFD, a backslash before a newline is no escape, and one at the end of a string is dropped.
- `CSS.escape("-")` is `"\-"`.
- `popover` is limited to its keywords: null without the attribute, `"auto"` for an empty one, `"manual"` for an unknown one.
- `script.nonce = …` sets the script's nonce and leaves its attribute, as for any element, and cloning carries a nonce set that way.

## 0.14.0 — 2026-10-01

### Added

- `innerText` and `outerText` on HTML elements, following the computed style (`display`, `visibility`, `white-space`, `text-transform`), `<br>`, block and `<p>` breaks, and table cells and rows.
- `getComputedStyle(el).direction` and `:dir()` follow the `dir` attribute, including `dir="auto"` and `<bdi>`.
- An HTML document is an `HTMLDocument`: `document.constructor === HTMLDocument`.
- The `formdata` event fires while a form's entry list is built, and the `FormData` a listener changes is what the form submits.
- `DataTransfer#items`, and an assignable `input.files`, so `dt.items.add(file); input.files = dt.files` attaches a file.
- A form submitted with a `target` that names an `<iframe>` loads the response into that frame and fires the frame's `load`; the top page stays.
- `Browser#frame_navigation_delegate(frame)` gives a frame whose document the host injected a delegate of its own, so a form or link inside it navigates the frame.
- `Window#event_source_connector` lets an embedder carry a page's `EventSource` connections; dommy-rack connects a same-origin one to the app.
- `Interaction::EventSynthesis.hover` / `.unhover` fire `mouseover` and a `mouseenter` on each newly entered ancestor (and the reverse), and `.right_click` / `.double_click` fire `contextmenu` and `dblclick`.
- A runtime may implement `execute_with_args` / `evaluate_with_args` to pass Ruby arguments to a script; dommy-rack and capybara-dommy use them when they are there.
- `StorageEvent`, `TextEvent`, `DeviceMotionEvent`, `DeviceOrientationEvent` and `TouchEvent`, the interfaces `document.createEvent` names.

### Changed

- **Requires makiri >= 0.12.0.** An element made by `createElementNS` in an HTML document is built in its namespace (an SVG `feGaussianBlur` keeps its case, `[viewBox]` finds it), and `setAttribute` of a name with a colon or `xmlns` goes through makiri's DOM `setAttribute` entry points.
- Names follow the DOM's own rules — valid element and attribute local names, namespace prefixes and doctype names — instead of the XML Name / QName productions: `createElement("A\v")` and `setAttributeNS("u", "\u0001:attr", …)` succeed, and `createElement("a/b")` throws `InvalidCharacterError`.
- `XMLSerializer` writes what Chrome, WebKit and Firefox write where WPT's cases disagree: an attribute keeps its own prefix unless that prefix is bound in scope (`xl:type` stays `xl:type`), and an `xmlns` that agrees with the element's namespace is kept.
- Inserting a doctype the backend could not create (one with an empty name) into a document throws `NotSupportedError`; it used to do nothing, and a `replaceChild` dropped the node it replaced. `createDocument` still leaves such a doctype out.
- Popovers fire `beforetoggle` and `toggle` as `ToggleEvent`s, whose `oldState` / `newState` replace the old `CustomEvent`'s `detail`; `toggle` is queued, and an opening `beforetoggle` can be canceled.
- **Breaking for backends:** the JS half is two bundles, not one — `HostBridge::WEBIDL_TABLES_JS` (the specs' own enumerations: interface members, constants, operation arities, event handler attributes) must be evaluated before `HOST_RUNTIME_JS`, which reads them. A backend that seeds through `HostBridge#seed_runtime!` needs no change; one that evaluates the runtime source itself does.
- A form submission runs interactive constraint validation first: an invalid form fires `invalid` at its controls and is not submitted, unless the form has `novalidate` or the submitter `formnovalidate`. `form.submit()` still skips it.
- A form's `enctype` decides the request body: a `text/plain` form sends plain text, and a `multipart/form-data` form a multipart body with its file parts, even with no file in it.
- **Breaking for embedders:** a navigation delegate's `navigate` receives a `target:` keyword, the submitting form's `target` / `formtarget`.
- **Breaking for backends:** the wire tags are `Dommy::Bridge::WireTags`, not `Dommy::Js::WireTags` — a tag is true of any host, so it belongs with the protocol. `Dommy::Bridge::Callback`, an adapter for an embedder that never arrived, is removed; `Dommy::Js::HostCallback` is the live one.

### Fixed

- An invalid `dir` value such as `dir="foo"` inherits the parent's direction, and `el.dir` / `document.dir` read `""` for it.
- `<dialog>` fires `beforetoggle` before `show()` / `showModal()` / `close()` change `open`, and a queued `toggle` after; only an opening `beforetoggle` can be canceled.
- An enumerated attribute returns its canonical keyword or default: `form.method` is `"get"` for a missing or unknown value, and `img.crossOrigin` is `null` without the attribute.
- `input.type` is `"text"` for an unknown type.
- `document.createElement("script").async` is `true`.
- `el.dataset["a<b"] = "x"` sets `data-a<b`, a name like `"-foo"` throws `SyntaxError`, and an element outside HTML, SVG and MathML has no `dataset`.
- `document.foo` finds an `<object id="foo">`, and a named `<object>` is the element itself rather than its content window.
- `crypto.getRandomValues(new Uint32Array(4))` fills and returns that same `Uint32Array`.
- An XHTML element in an XML document has its HTML interface (`<body>` is an `HTMLBodyElement`), and an element in no namespace is a plain `Element` in any document.
- `innerHTML` and `outerHTML` in an XML document parse the markup in the namespaces in scope on the element, and mark its scripts already started.
- `outerHTML = "<a></a><b></b>"` inserts the nodes in order when the element has a next sibling.
- The HTML serialization writes a nested `<template>`'s contents: `body.innerHTML` after `body.innerHTML = "<template><i></i></template>"` includes the `<i></i>`.
- A `<template>` parsed from XML keeps its children in its template contents, as in a browser, and `innerHTML`, `XMLSerializer`, `importNode` and moving it to an HTML document follow the contents.
- An element imported or moved from an HTML document into an XML one gains no `xmlns` attribute, and `XMLSerializer` declares its namespace only where the tree needs it.
- `importNode` keeps an attribute's name as written: a `setAttribute("A:B", …)` from an XHTML document stays `A:B` in an HTML one.
- `<textarea>` answers `selectionStart`, `selectionEnd` and `selectionDirection`, and `setSelectionRange` / `select` move them — they used to return nothing and do nothing.
- Decoding a whole buffer of valid UTF-8 — what `XMLHttpRequest#responseText` does — takes Ruby's own path instead of the spec's byte-at-a-time decoder, around 200x faster on a large response.
- A `charset` inside a quoted MIME parameter, as in `boundary="a;charset=utf-8"`, is that value's text and no longer read as the charset.
- `Bridge::Bytes.new` reads a String as the packed bytes it is, where it used to wrap it and take `to_i` of the whole thing — one zero byte, silently.
- A static method a `Bridge::Constructor` does not have raises `TypeError` instead of answering null.
- `Element.prototype.classList` has a setter, as `[PutForwards=value]` requires, so assigning to it rewrites the class attribute through the list.
- A `[LegacyNullToEmptyString]` setter turns null into the empty string rather than "null": `text.data`, `input.value`, `textarea.value`, `media.mediaText`, `img.border`, `font.color`, `innerText` and `outerText` join `innerHTML` and `outerHTML`.
- `window.location`, `window.document`, `window.top` and `window.window` are own, non-configurable properties of the window, as `[LegacyUnforgeable]` requires — a page cannot replace them.
- `element.slot` is `[Unscopable]`, so `with (element) { slot }` reaches the outer binding, and a `data-*` name resolves before `DOMStringMap.prototype`.
- An operation whose WebIDL return type is `undefined` answers with `undefined` rather than `null` — `text.appendData("x")`, `history.go(0)`, `localStorage.clear()`, `xhr.open(...)` and around ninety more.
- `location.replace.length` is 1 and `location.assign.length` is 1, where both reported the arity of the same-named `DOMTokenList` operation.
- A collection gets `keys()` / `values()` / `entries()` / `forEach()` only when its IDL declares `iterable<>`: `CSSRuleList`, `FileList`, `MediaList`, `DOMStringList`, `NamedNodeMap` and `DataTransferItemList` no longer carry methods the spec does not give them.
- `base.href` resolves against the document's fallback base URL instead of returning the attribute verbatim — a `<base>` does not resolve its own href against itself.
- `progress.value = 5` writes "5", not "5.0", and rejects a non-finite value like `<meter>`'s setters already did.
- `img.width` / `img.height` parse the content attribute as HTML does ("12abc" is 12, "-5" is 0), and their setters convert out of range before writing.
- `form.relList` exists, and `iframe.sandbox` / `link.sizes` are the `DOMTokenList` they reflect rather than a string — assigning to one forwards to its `value`, as `[PutForwards=value]` requires.
- `input.readOnly`, `input.multiple`, `select.disabled` / `required`, `textarea.disabled` / `readOnly` / `required`, `link.disabled` and `option.defaultSelected` reflect on the interfaces that declare them, so a `select` no longer answers `readOnly` and feature detection reads it as the select it is.
- A named `<button>` outside a form, associated with it by a `form` attribute, is no longer an entry in that form's `FormData`: a submit button is an entry only as the submitter.
- Reflected `long` and `unsigned long` attributes answer HTML's algorithm rather than `String#to_i`: `td.colSpan` falls back to 1 and clamps to 1000, `rowSpan` clamps to 65534, `ol.start` and `select.size` fall back where the value is out of range, and a negative value reaches only the signed ones. `cell.colSpan = 3000000000` stores "1", as the setter's own range conversion requires.
- URL-reflecting IDL attributes return a resolved URL, where they used to return the content attribute verbatim: `img.src`, `script.src`, `link.href`, `iframe.src`, `embed.src`, `object.data`, `source.src`, `track.src`, `video.poster`, the media `src`, `img.longDesc`, and `q` / `blockquote` / `ins` / `del`'s `cite`. `form.action` resolves too, and reports the document's URL when the attribute is missing or empty, as `formAction` already did.
- `location.hash = ""` leaves the "#" in `href` when there was a fragment to clear, and leaves a fragmentless URL alone. Location's setter is not the URL API's, where the empty string sets the fragment to null.
- `take(NaN)` and `take(Infinity)` take nothing, and `drop(NaN)` drops nothing — WebIDL's `unsigned long long` answers zero for a non-finite count, where they used to mean "unlimited".
- `reportError(e)` reports the position the error carries — its own JS frames, minus Dommy's own plumbing — where it used to report line 0 of no file. An unhandled Observable error reports through that same funnel now, so it reaches the console and the host, not only an `error` listener.
- Setting a form control's `value` through its prototype accessor — the descriptor React's value tracker wraps — invalidates the DOM caches, so a read after `select.value = x` sees the new selection rather than the epoch's stale snapshot.
- `Object.defineProperty(localStorage, k, {value})` propagates a setter the spec says throws, where it used to swallow it.
- `select.labels` lists the labels that name it, including a wrapping `<label>`, and no longer breaks on an id containing a quote.
- An element hidden with `aria-hidden="TRUE"` is hidden from its accessible name too, not only from the accessibility tree.
- A custom element reaction that throws — `connectedCallback`, `disconnectedCallback`, `attributeChangedCallback` — is reported at the window, where it used to vanish.
- `var()` keeps a name argument that is not a custom property name, such as `var(--x ())` or `var({--x})`: the declaration parses and goes invalid at computed-value time, as the CSS Variables grammar asks.
- `relList` on the `a` of the MathML namespace is a DOMTokenList, as it already was in HTML and SVG.
- `compareDocumentPosition` between two trees orders the pair consistently: one node reports PRECEDING and the other FOLLOWING, where both used to say PRECEDING.
- A parsed SVG element reports its own `tagName` (`rect`, not `RECT`) and a prefixed element parsed from XML its `localName` (`coreProperties` for `cp:coreProperties`), so `querySelector("coreProperties")` and `getElementsByTagNameNS` find it. An element parsed from XML in no namespace has a null `namespaceURI`, not the HTML namespace.
- `innerHTML` / `outerHTML` outside an HTML document serialize as XML, and their setters parse XML, throwing `SyntaxError` for markup that is not well-formed; they used to raise a backend error.
- `createDocument(ns, name, doctype)` appends that doctype itself, so `doc.firstChild === doctype` and its `parentNode` / `ownerDocument` follow; it used to place a copy.
- `adoptNode` / a cross-document insert of an upper-case HTML-namespace element such as `BR` keeps it and its name instead of raising a backend error.
- A `DocumentFragment` and a `ShadowRoot` report `null` for `nextSibling` / `previousSibling` (and a `ShadowRoot` for `parentNode`, `parentElement` and `nodeValue`), not `undefined`.
- A `<script>` from `DOMParser` stays inert when adopted, cloned or imported into the page; `cloneNode` / `importNode` of a script copy its "already started" flag.
- A form converts its names and values to the submission encoding (`accept-charset`), writing `&#N;` for a character the encoding lacks, and a multipart part's name or filename percent-encodes CR and LF.
- `enctype="MULTIPART/FORM-DATA"` is multipart: an enumerated attribute matches case-insensitively, and an unknown value means urlencoded.
- A form's entry list follows the collection rules in full: a value-less hidden `_charset_` reports the encoding, `dirname` adds the control's direction, a disabled `<option>` is left out, and a disabled `<fieldset>` spares only the controls in its first `<legend>`.
- A submit button submits its `value` property, so `button.value = "x"` reaches the form data without touching the attribute.
- An `<input>` a `click` listener turns into a submit button submits the form.
- `new SubmitEvent("submit", {submitter: 1})` and a `FormDataEvent` without a `FormData` throw `TypeError`, and a missing submitter reads `null`.
- `document.onreadystatechange = f` and the other `on*` handlers on the document fire, where the assignment used to set a plain property.
- Both clicks of a double click run the full pointer and mouse sequence, and the second one's activation behavior.
- `new URL(location)` and `new URL(anchor)` take the object's `href`.
- Assigning to a read-only attribute such as `url.searchParams` or `template.content` throws `TypeError` in strict mode and does nothing otherwise. `legend.form` is `null` without a `<fieldset>`.
- `document.createEvent` matches its type case-insensitively against the DOM's table and throws `NotSupportedError` for a type the table lacks, such as `"foo"`. `delete window.Event` removes the interface.
- The `autocomplete` getter answers HTML's autofill processing: `""` without the attribute, and the folded value (`"shipping email"`) with one.
- `dialog.show()` on a modal dialog throws `InvalidStateError`, and `showModal()` on a non-modal open one does too; each is a no-op on a dialog it opened itself.
- A `<script>` parsed into a `<template>`'s contents reports `async` as `false`.
- `document.styleSheets` is a `StyleSheetList`, without `forEach` or `entries`.
- An interface constructor's `length` is its required argument count (`Event.length === 1`), a `[SameObject]` collection such as `document.forms` or `table.rows` is the same object on every read, and `rule.style = "color: red"` writes the declaration block.
- `el.scrollTo()`, `scrollBy()`, `scrollIntoView()` and the window's return a `Promise`, and `mediaQueryList.addListener()` returns `undefined`.
- `<script src="">` counts as an external script and `<iframe src="">` is not the blank frame, as HTML asks whether the attribute is present rather than empty.
- `XMLHttpRequest#send` sends no body for `GET` and `HEAD`, and with a string, document or `URLSearchParams` body corrects an author-set `Content-Type` charset to `UTF-8`, the encoding the body was sent in.
- `hsl(120 none 50%)` computes to itself, keeping the missing component, instead of `rgb(128, 128, 128)`.
- Clicking a `<meter>`, `<output>` or `<progress>` inside a `<label>` no longer overflows the stack.
- An `<iframe>` with no `src` or `srcdoc` is at `about:blank` (`about:srcdoc` for `srcdoc`) and resolves relative URLs against the base URL of the document that created it.
- Loading the URL pattern code on Ruby 4.0 prints no "character class has duplicated range" warning.
- An SVG element never runs HTML's steps for an element of its name: an SVG `<script>` is not in `document.scripts`, and SVG's `<a>` and `<option>` are not in `document.links` or `select.options`.

## 0.13.0 — 2026-09-23

### Changed

- Uncaught JavaScript goes through WHATWG's "report an exception": a cancelable `error` event fires at the window, and only what the page leaves unhandled reaches the host's log.
- An exception in a timer or animation-frame callback is reported at the window.
- `reportError()` reports at the window instead of being swallowed.
- A `<script>` that throws hands the page a real `Error` as `event.error`, so `e.error.message` reads.
- `ErrorEvent` says where the page failed, in `filename`, `lineno` and `colno`.
- A `<script src>` that throws after a successful download fires `load`.
- `unhandledrejection` carries the rejected value as `event.reason`, and `rejectionhandled` fires when a handler arrives late.
- **Breaking:** `Dommy::Browser::JsError` is `Dommy::JsError`, with no alias for the old name, and the errors live in a shared `Browser#error_log`.
- `js_errors` holds only what the page left unhandled: an error canceled in `window.onerror` never reaches it.
- `TextDecoder` throws `RangeError` for a label the Encoding Standard does not name.
- `XMLHttpRequest#responseText` decodes in the response's charset.
- A URL component setter leaves the URL unchanged when the parser rejects the value.
- `<a>` and `<area>` read and write their URL against the document base URL.
- `new URL("https://xn--/")` parses: an A-label that does not decode is a host, as in browsers.
- `XMLHttpRequest.open` and `location.href` throw a `SyntaxError` on a URL the parser rejects.
- Streams follow the Streams Standard.

### Fixed

- A number input sanitizes `" 1"` to `""`.
- `new FormData(null)` throws `TypeError`, and `new FormData(undefined)` is an empty FormData.
- A method with no return value answers `undefined` to JavaScript.
- `stepUp` with `step="0.1"` reaches `0.3`, not `0.30000000000000004`.
- `window.event` honors an assignment.
- `Request#formData()` parses a urlencoded or multipart body.

## 0.12.0 — 2026-09-22

### Added

- `StaticRange`.
- The rest of the Selection API: `setPosition`, `collapseToStart`, `collapseToEnd`, `extend` (`extend_selection` in Ruby), `setBaseAndExtent`, `deleteFromDocument`, `containsNode`, `direction` and `getComposedRanges`.
- `moveBefore` runs the custom element move reactions: `connectedMoveCallback`, or `disconnectedCallback` then `connectedCallback` when it is not defined.
- `cloneNode` on every node: Text, Comment, CDATASection, ProcessingInstruction and DocumentFragment answer it from Ruby, not only Document, Element and DocumentType.
- `setAttributeNodeNS`.

### Changed

- `URLPattern` follows the spec. The constructor takes a pattern string with an optional base URL or an init dictionary, and `ignoreCase`; the component getters return the normalized pattern strings; `hasRegExpGroups` is there; `test` and `exec` take a URL string with an optional base URL, an init dictionary or a URL, and read the components the way the URL parser would. Fixed text is canonicalized per component, so `/café` is `/caf%C3%A9` and `café.com` is `xn--caf-dma.com`, and a pattern that is not well formed, a duplicate name, a regexp ECMAScript rejects or a hostname the URL parser rejects throws `TypeError`. Matching runs in Ruby: the regexps the spec compiles with the `v` flag are translated to Onigmo, keeping ECMAScript's `\s`, `\b`, `.`, anchors, named groups, `[a--b]` and empty-iteration semantics. A relative URL string without a base URL no longer matches. WPT urlpattern: 3 to 391 of 425 subtests; what is left is the tentative `compareComponent` and `generate`.
- Requires `makiri >= 0.10.0`.
- Selection holds at most one range: a second `addRange` is ignored, and a range that leaves the document is dropped from the selection.
- `document.getSelection()` returns `null` for a document without a browsing context.
- Range methods throw `TypeError` for an argument that is not a Node, `null` included.
- `Range#containsNode` is no longer exposed to JavaScript.

### Fixed

- Range: `selectNode` and `setStartBefore` / `setStartAfter` / `setEndBefore` / `setEndAfter` on a node without a parent, `selectNodeContents` on a doctype, `deleteContents` with nested contained nodes, `insertNode` validity and end offset, and `toString` with CDATA sections.
- `TreeWalker.parentNode()` after the current node is removed from under the root.
- Events dispatched at a Text or Comment node reach its ancestors in the right phase.
- `normalize()` on the Document and on nodes without children; `getRootNode({composed: true})` from a node in a shadow tree.
- `moveBefore` throws `TypeError` for a `child` that is not a Node; `doctype.isConnected`.
- Custom elements in shadow trees get `connectedCallback` / `disconnectedCallback` and are upgraded by `customElements.define()` and `upgrade()`. An upgraded shadow host keeps its `shadowRoot`, and a callback that attaches a shadow tree no longer causes reactions to run twice.
- An element created before its `customElements.define()` is upgraded in place, so references a script already holds become instances of the class.
- Cloning and `importNode` keep the interface, namespace and attributes of the original: a ProcessingInstruction no longer comes back as a Comment, an SVG `rect` as an HTML `RECT`, or an `xml:b` attribute as one named `"xml:b"`. A CDATASection clones to a CDATASection over the JS bridge, a shadow root refuses `cloneNode` with `NotSupportedError`, and `importNode` of a document or a shadow root throws `NotSupportedError` instead of returning `null`.
- `document.cloneNode(true)` holds clones of the original's children and nothing else, instead of a re-parsed document that grew an html/head/body.
- `removeAttributeNode` throws `NotFoundError` for an Attr that belongs to another element.
- Processing instructions serialize as `<?target data?>` in HTML documents.
- Selectors: a type selector is case-sensitive except for HTML elements in an HTML document, so `rect` matches an SVG `rect` and `RECT` does not; SVG tag names such as `feMerge` keep their camel case. An attribute selector without a namespace matches only attributes in no namespace, so `[a]` no longer matches `xml:a`.
- Selector syntax follows CSS Syntax: NULL is U+FFFD and newlines are LF, non-ASCII ident code points are the spec's list, `.--foo` is a selector, a dangling backslash ends in U+FFFD, an unclosed `a[href` is closed at the end of the input instead of raising a `TypeError`, comments sit between any two tokens, `#1` is not an id selector, and a sign binds to the token after it in An+B.
- JavaScript: `moveBefore` and the AbstractRange and Range members are on their prototypes, `Selection.prototype.collapse.length` is 1, and `toString.length` is 0.
- Every constructor the window has is a global scripts can name. `URLPattern`, `TextDecoderStream`, `TextEncoderStream`, `CompressionStream`, `DecompressionStream`, `PointerEvent`, `InputEvent`, `DragEvent`, `TouchEvent`, `Touch`, `ClipboardEvent`, `BeforeUnloadEvent`, `ProgressEvent`, `Animation` and `KeyframeEffect` were `undefined` in JavaScript, and `URLPattern`'s members are on its prototype. `InputEvent` and `TouchEvent` are UIEvents.

## 0.11.0 — 2026-09-11

Conformance, mostly. Two sources drove this release: running the same script in
headless Chromium and in Dommy and diffing the result, and checking Dommy's
behaviour against a Lean 4 formalization of the DOM standard. Both find things
WPT does not. The other half is performance on JavaScript-heavy pages.

### Added

#### DOM
- `ParentNode.moveBefore(node, child)` — relocate a node without removing and re-inserting it: no `disconnectedCallback` / `connectedCallback`, no adoption, and a live Range or NodeIterator follows the node instead of being pushed off it.
- Every node answers Node's mutation methods from Ruby (`append_child`, `insert_before`, `replace_child`, `remove_child`) and `owner_document`. A leaf node — Text, Comment, DocumentType — rejects an insertion with `HierarchyRequestError`, which is what the spec says, instead of raising `NoMethodError`.
- A `<!doctype>` is an ordinary child node: `before` / `after` / `replace_with` / `remove` work on it, run the document's own hierarchy checks, and move live ranges like any other child.

#### HTML
- `<details name="…">` exclusive accordion groups: opening one member closes the others, and a `<details open>` the parser produced gets the `toggle` event it owes.

#### CSSOM
- `new CSSStyleSheet()` is constructable, for component bundles that prepare their CSS before attaching it. (`adoptedStyleSheets` itself is still unimplemented; such a bundle falls back to injecting a `<style>`, which Dommy handles.)

#### JavaScript
- Legacy `window.event`: a bare `event` identifier inside a listener resolves to the event being dispatched, so a handler written without a parameter works.
- A listener that throws is now **reported** instead of silently swallowed — it fires an `error` event at the window, so `window.onerror` and an `"error"` listener see it, and `event.error` is the thrown value itself (identity preserved, so `e.error === thrown`). Dispatch continues with the remaining listeners either way.

#### Host seams
- `Window#dialog_handler` — supply deterministic answers for `alert` / `confirm` / `prompt`. With no handler, or one that declines a particular dialog, the headless defaults stand (`nil` / `false` / `nil`).

### Changed

- **Attributes are matched by qualified name.** `getAttribute` / `setAttribute` / `removeAttribute` / `hasAttribute` / `toggleAttribute` are defined on an attribute's qualified name, so an element carrying only `xml:b` no longer answers a read of `b`, and writing `b` adds a second attribute instead of overwriting the prefixed one. `setAttribute` also keeps an existing attribute's namespace rather than replacing it with a null-namespace one.
- **CSS property names follow the CSS rule, in both declaration blocks.** An element's `style` and a style rule's `style` are now parsed by one implementation: a property name is ASCII case-insensitive (`style="COLOR: red"` reads back as `color`) except a custom property, whose name is case-sensitive (`--Foo` and `--foo` stay two properties). The name handed to `getPropertyValue` / `setProperty` / `removeProperty` is normalized the same way, and a declaration whose value cannot be parsed is dropped in a rule as it already was inline.
- **A `<select>`'s selectedness is settled when its list changes**, rather than derived every time it is read. A single-select ends up with exactly one option selected when the rules call for it and keeps an explicit `selectedIndex = -1`; adding, moving or removing options re-settles the list, as do the `multiple` and `size` attributes.
- **Requires makiri >= 0.9.0.**

### Fixed

#### Events and dispatch
- `dispatchEvent` on an event whose dispatch is already in flight throws `InvalidStateError`. A listener that re-dispatched the event it was handling used to recurse until the Ruby stack overflowed.
- At the target, capture listeners run before bubble listeners, and `stopPropagation` from a capture listener also skips the target's own bubble listeners.
- A listener removed during a dispatch is not invoked by that dispatch — including a `once` listener that a nested dispatch consumed while an outer dispatch was still walking its snapshot.
- The event path is built as the spec describes it: a slotted node composes into its assigned slot, a closed tree hides what it should, and `relatedTarget` is retargeted per node.
- Click activation runs inside dispatch, so a listener can `preventDefault` it; form reset runs as an activation behavior.
- `click()` on an "actually disabled" form control dispatches nothing — including a control inside a `<fieldset disabled>`, while one in that fieldset's first `<legend>` stays enabled.
- An element that arrived after boot already carrying `onclick="…"` — through `cloneNode`, `innerHTML`, or a template's content — now runs its handler: content attribute handlers compile lazily, and only the attributes that really are event handlers compile at all.
- A plain JavaScript object with a `handleEvent` method (Stimulus's action listeners, for instance) crosses as a live listener: it keeps its identity, is called with itself as `this`, and `handleEvent` is looked up fresh on each dispatch.
- Space activates a focused button-like control (a `<button>`, or an `<input>` button / checkbox / radio) instead of typing a space into it.
- A label click focuses its control before activating it, which is what a visually hidden submit input behind a label relies on; and a label leaves every kind of interactive content alone (a `<details>`, `<video controls>`, `<iframe>`, a nested `<label>`, …), not only links and form controls.

#### Shadow DOM
- `event.target` is retargeted per node, so a listener outside a shadow boundary sees the host and one inside sees the real node; an event that never left a shadow tree ends with `target` null instead of leaking an encapsulated node.
- Wrapping a shadow tree's backing fragment yields its `ShadowRoot`, so a walk out of the tree no longer dead-ends at a host-less fragment.

#### Ranges and traversal
- `cloneContents` / `extractContents` implement the recursive algorithms: a range ending mid-text yields the part it covers rather than the whole node, and a range with both boundaries in one Text node is no longer empty — which also stops `surroundContents` from destroying the selected text.
- `surroundContents` validates its arguments, and `setStart` / `setEnd` reject a DocumentType boundary and an out-of-range offset.
- Live ranges follow the tree through insertion, removal, `replaceData` and `splitText`, and `insertNode` places the node and grows a collapsed range over it per spec. Offsets into text are UTF-16 code units, as the spec requires.
- A `TreeWalker` rooted at the document can reach its own root, and its filter runs on the way up.
- Node iterators are tracked weakly, so an unreachable one stops costing work on every removal (live ranges already were).

#### Tree mutation
- `before` / `after` / `replaceWith` run the parent's pre-insertion validity checks, so an insertion a Document would refuse — a second element child, a Text child, a misplaced doctype — is rejected instead of building an invalid tree.
- The hierarchy checks run in spec order and count the document among its descendants' ancestors, so `element.insertBefore(document, ref)` is a `HierarchyRequestError` rather than a complaint about `ref`, and `insertBefore(x, x)` is validated before the reference is swapped.
- `document.replaceChild(fragment, child)` inserts the fragment's children instead of the fragment itself.
- Mutating a Document's, a ShadowRoot's or a `<template>`'s children runs the same removing steps as anywhere else, so the old parent gets its record, live ranges move, and node iterators follow.
- The live-range offset shift happens where the spec puts it — before the nodes are moved — so a range inside the node being inserted lands on the right offset.

#### Mutation observers
- A childList record carries its insertion point: `previousSibling` and `nextSibling`, read before the tree moves — `before` / `after` / `append` / `prepend` / `appendChild` left both null.
- Observers are notified in the order the spec reaches their registrations (the target's inclusive ancestors, nearest first), matched by scope **and** record type, with each registration's own options — a registration that does not ask for this type no longer shadows another that does.
- A Document observer with `subtree` no longer matches nodes outside that document: mutating a detached node used to queue a record on it.
- Removing a node registers the transient observers the spec calls for even when the removal suppresses its own record, and `takeRecords` no longer ends their lifetime — only a microtask checkpoint does.
- An attribute record keeps the attribute's case and namespace; `splitText` queues its `characterData` record before its `childList` one, as every engine does; `normalize` merges one sibling at a time and queues a record per sibling.

#### Forms and validation
- A form's named getter (`form.controlName`) follows the spec's past-names map, and a control's form owner is resolved in the right tree scope.
- `formAction` is a URL-reflecting IDL attribute — it resolves against the document base URL and falls back to the document's own address — and `formEnctype` / `formMethod` / `formTarget` / `formNoValidate` exist on `<input>` as well as `<button>`.
- `<a>` and `<area>` share the URL-decomposition attributes: `anchor.href = url` writes the content attribute instead of landing on a JS expando, and `area` has the full set (`hash`, `host`, `protocol`, …) resolving properly.
- `pattern` is compiled as a JavaScript RegExp with the `v` flag and ignored entirely when that throws, and on a `multiple` email control it is matched against each entry rather than the list.
- `stepMismatch` no longer needs `bigdecimal`, which Ruby 3.4 stopped shipping by default — on 3.4 the check raised `LoadError` in any bundle that did not list the gem.

#### Selectors
- `:link` / `:any-link` match hyperlinks only (an `a` or `area` with an href), not a `<link href>`; `:target` requires the element to be in the document.
- An attribute selector's name is ASCII-lowercased only for HTML elements in an HTML document, and class tokens are split on HTML ASCII whitespace.
- Queries on an XML document no longer raise.
- Selector state caches are invalidated when an IDL property write changes what matches — an input's `value` or `checked`, an option's `selectedness` — so `:checked` / `:valid` / `:invalid` answer the new state, and `:empty` still sees a text change.

#### CSSOM
- `var()` has a grammar: `var(--x ())` is a syntax error and the declaration is dropped rather than stored. Setting a value the block refuses, or removing a property that was never set, is not a change, so neither rewrites the `style` attribute nor queues a record.
- Each rule kind reports its own interface (`CSSStyleRule`, `CSSMediaRule`, `CSSSupportsRule`, …), and rules serialize per spec.
- Within one declaration block an important declaration beats a normal one for the same property whatever their order; `setProperty` takes a priority, `getPropertyPriority` exists, and `cssText` round-trips `!important` without leaking it into the value.

#### Accessibility
- ARIA 1.2's `image` is the canonical role and `img` its deprecated synonym (the mapping ran the other way).
- A `<summary>` is named from its contents whatever role it computes to, a label's encapsulation is respected, and hidden subtrees stay out of the name.

#### Parsing and serialization
- `createElement` / `createElementNS` accept every valid XML Name.
- `document.documentElement` is null when the document has no element child, instead of answering with the doctype.
- A `<template>`'s contents travel with it across documents — `importNode`, `adoptNode` and a cross-document insert — keeping the same content fragment and the children in it.
- `XMLSerializer` drops an `xmlns` that contradicts the element's real namespace, matching it on its local name, so `setAttribute("xmlns", …)` no longer produces a duplicate declaration.
- `importNode` of an `Attr` returns a copy rather than null, and a doctype keeps its identity through the factories.

#### JavaScript bridge
- Dommy's JavaScript-visible surface is now audited against the WebIDL the specs publish (240 interfaces from 10 specs), and the properties and methods that audit found missing or misplaced are in place.
- A JS event's stop-propagation flag is cleared when dispatch completes, a method extracted from a prototype still routes through the proxy wrappers, and every path that cancels an event goes through one place.

### Performance

- **Style invalidation is split into DOM and style epochs, and plain rules match lazily through a rule hash.** A mutate-then-read loop — the shape of a Turbo morph or an assertion after an edit — went from ~65 ms per operation to ~5 µs for a style-neutral mutation, and from ~63 ms to ~0.7 ms when the mutation really does change what matches.
- **The JS bridge crosses less.** Events are constructed JS-side with a lazy host twin, framework expandos stay JS-side, an unlistened namespaced event dispatches in one crossing, and interface members are shared through a per-interface prototype: a 300-row Turbo morph went from ~405 ms to ~285 ms.
- Attribute reads go through the backend's native qualified-name lookup (makiri 0.9.0), and a mutation no longer walks the target's ancestors when no `MutationObserver` is registered.

## 0.10.0 — 2026-07-13

### Added

#### Navigation
- Page navigation now happens: clicking a link, assigning `location`/`location.href`, and submitting a form (`form.submit()` / `requestSubmit()`, or pressing Enter) trigger real transitions. Your app owns them through a navigation delegate; cross-document navigation loads the target and replaces the document, and `<meta http-equiv=refresh>` is honored.

#### Networking (fetch / XHR)
- `fetch` follows redirects and enforces CORS — preflight, credentials, the `same-origin` / `no-cors` / `cors` modes, and response filtering — and sends the default headers a browser adds.
- `XMLHttpRequest` supports the standard `readyState` flow, `responseType`, and request bodies (string, `Blob`, `ArrayBuffer`, typed arrays), with UTF-8/BOM-aware JSON responses.

#### Forms & validation
- Constraint validation across control types: `checkValidity` / `reportValidity` / `validity` cover `valueMissing`, `tooLong` / `tooShort`, `rangeOverflow` / `rangeUnderflow`, `stepMismatch`, `patternMismatch`, `typeMismatch`, `badInput`, and `customError` (including email and `pattern`). `willValidate` accounts for disabled controls, controls inside a `<fieldset disabled>`, and non-submit buttons.
- `<input>`: `valueAsNumber`, `stepUp` / `stepDown` (number/range/date/time/month/week), radio-group behavior, a text-selection API, and `.list` (the associated `<datalist>`).
- `<select>` / `<option>` selection model and options collection; `<textarea>` value vs. `defaultValue`; `<meter>` / `<progress>` value clamping; `form.elements` with named access (`form.controlName`); labelable elements and `label.control`.
- Cloning a form keeps user input — a cloned `<input>` / `<textarea>` retains its current value and checked state instead of reverting to the defaults.

#### Tables
- The table DOM API is available: `caption` / `createCaption` / `deleteCaption`, `tHead` / `tFoot` / `tBodies` / `createTBody`, `rows` / `insertRow` / `deleteRow`, `cells` / `insertCell` / `deleteCell`, and `rowIndex` / `sectionRowIndex` / `cellIndex`.

#### Events & interaction
- Inline handlers (`onclick="…"`) run, including handlers added at runtime with `setAttribute`, and a handler's return value is honored (`return false` cancels the default action).
- **Keyboard:** `Driver#send_keys` types text and named keys (`:enter`, `:arrow_down`, …) through the full key-event sequence with browser default actions (typing, Backspace, Enter to submit / insert a newline).
- **IME:** `Driver#ime_input` drives a composition sequence (`compositionstart` / `update` / `end`, `CompositionEvent`) with commit and cancel.
- **Focus:** `Element#focus` / `#blur` move `document.activeElement` and fire `blur` / `focusout` then `focus` / `focusin`.
- More event types are available to JavaScript — `UIEvent`, `MouseEvent`, `KeyboardEvent` (with `keyCode` / `charCode` / `which`, `code`, `getModifierState`, …), `WheelEvent`, `FocusEvent`, `CompositionEvent` — and subclassing `Event` / `EventTarget` works.
- `<details>` fires `toggle` (with exclusive-accordion grouping by `name`); `<dialog>` fires `close` and reports an error from `showModal` when already open.
- Host integration seams: `Window#websocket_connector` lets your app back `new WebSocket(url)`, and `History` reports `pushState` / `replaceState` / traversal so a session can mirror navigation (`Window#history` is now readable).

#### DOM & JavaScript
- Broader, spec-aligned DOM: `ChildNode` `before` / `after` / `replaceWith`, insertion hierarchy validation, `DocumentType` in the tree, `cloneNode` namespace preservation, `Text.wholeText`, `document.head`, `Range.createContextualFragment`, `Attr.baseURI` / `ownerDocument`, `lookupNamespaceURI` / `lookupPrefix`, `lang` / `translate`, `ShadowRoot.activeElement` / `styleSheets`, `Text.assignedSlot`, and anchor stringification (`String(a) === a.href`).
- Custom elements: `customElements.define` and direct `new MyElement()` construction.
- A blank `<iframe>` now has a working `contentDocument` / `contentWindow` with its own constructors.
- `getElementsByClassName` / `getElementsByTagName` / `HTMLCollection.namedItem` follow the standard matching rules.

#### Selectors & CSS
- New selectors: `:valid` / `:invalid` / `:required` / `:optional` / `:read-only` / `:read-write`; `:is()` / `:where()` accept an empty list.

#### Accessibility
- ARIA element-reference reflection (e.g. `ariaActiveDescendantElement`) with scope validation.

### Changed
- Some previously lenient behaviors are now spec-correct and may change observed results:
  - Setting a `<textarea>`'s `value` no longer changes its child text (its default value).
  - Mutating an element's inline `style` keeps the `style` attribute present (empty `style=""` rather than removing it).
  - `document.head` is read-only and resolves to the first HTML `<head>` child of the document element.
  - `td` / `th` `cellIndex` is `-1` unless its direct parent is a `<tr>`.
  - `document.title` collapses only ASCII whitespace; `Document` / `DocumentFragment` `nodeValue` is `null`; `btoa(null)` encodes `"null"`; `location.port` is empty for a default port.

### Fixed
- URL / form decoding no longer relies on the stdlib CGI library (fixes a `NameError` on Ruby 3.3 and under Ruby 4.0). `decodeURIComponent` leaves `+` literal, and `encodeURIComponent` keeps the full JavaScript unreserved set (`- _ . ! ~ * ' ( )`) literal.

### Performance
- Faster selector matching and DOM queries, from cached selector parsing and cached DOM reads.

### Dependencies
- Requires `makiri >= 0.8.0`.

## 0.9.0 — 2026-06-22

The major release that brings JavaScript to Dommy. A new engine-agnostic JS
runtime and JS↔Ruby DOM bridge (with `dommy-js-quickjs` as the first backend)
sit on a WHATWG event loop — microtasks, timers, async fetch/XHR, Promises/A+,
Workers, and `postMessage`. Alongside it: a from-scratch CSS cascade and
computed-style engine, a Playwright-compatible accessibility tree, and a switch
of the parser backend to Makiri (Lexbor, no libxml2).

### Added

#### JavaScript — runtime & bridge
- An engine-agnostic JS runtime host layer: a `Dommy::Js::Runtime` port contract plus a backend registry (`register_runtime` / `default_runtime` / `build_runtime`); the core gem runs no JS itself and raises a clear error when no backend is registered. A backend gem (`dommy-js-quickjs`) plugs in underneath.
- The engine-agnostic JS↔Ruby DOM bridge moved into core: marshalling, the tagged-value wire protocol, the JS-handle table, WebIDL interface derivation, reverse construction (`new Event(...)`), and `customElements.define` wiring.
- `Dommy::Browser`, a standalone JS-capable test browser, plus script-boot orchestration (import maps, module loading).
- JS-runtime integration seams: a page-load hook, a fetch handler, and a time pump.
- Legacy named constructors `Image` / `Audio` / `Option`.
- Bridge diagnostics: a crossing-count profiler and rejection-detail capture.

#### JavaScript — event loop & scheduler
- An async-network foundation: a scheduler inbox and deferred `fetch` (resolved as a networking task rather than inline).
- A microtask checkpoint after each task, per the WHATWG event loop.
- Deeply-nested timers clamp to 4 ms (HTML timer steps).
- Real-time tracking in browser mode so concurrent renders can yield.

#### JavaScript — Promises
- `Promise.prototype.finally` (ES2018).
- A native `window.Promise` plus `PromiseRejectionEvent`.

#### JavaScript — scripts & modules
- Execution of dynamically-inserted external `<script src>`, run asynchronously; inserted-script `load` / `error` events fire asynchronously.
- Module scripts deferred until after parser-blocking classic scripts.

#### JavaScript — async networking (fetch / XHR / streams)
- `XMLHttpRequest` resolves a deferred (async) response.
- `data:` URIs resolve in `fetch` / `XMLHttpRequest`.
- `ReadableStream` is async-iterable (`Symbol.asyncIterator`).

#### JavaScript — workers, messaging & window globals
- `window.alert` / `confirm` / `prompt` / `reportError` / `getSelection` / `postMessage`; `postMessage` and Worker messages deliver via a task (not a microtask).
- `window.btoa` / `atob`.
- `navigator.hardwareConcurrency` / `maxTouchPoints` / `sendBeacon`.
- `window.screen` (`Screen` + `ScreenOrientation`).
- The `ErrorEvent` interface.
- `window.console` / `Object` / `Array` / `JSON` are the native engine globals.

#### CSS — cascade & computed styles
- A full CSS cascade and `getComputedStyle` engine: UA + `<style>` + inline precedence with `!important` levels, CSS-wide keywords (incl. `revert`), inheritance/initial defaulting, and font-size-first computation so `em` / `rem` / `%` resolve to px without layout.
- `:visible` is now stylesheet-aware (detects class-driven `display:none` and inherited `visibility:hidden`); `:focus` / `:checked` / `:hover` / `:target` pseudo-classes; broadened selector matching (namespaces, `:visited`, `:lang`).
- Custom properties and `var()`; viewport environment and media queries (`MediaList`).
- CSSOM rules wired to the parser; `document.styleSheets` populated; `<link rel=stylesheet>` and `@import` sheets fetched and applied.
- `@layer` cascade-layer ordering, `@scope` (scoped styling + proximity), `@supports` / `CSS.supports()`, `@namespace`, pseudo-element rules, Shadow DOM CSS scoping, and CSS counters for generated content.
- `currentColor` resolution, the css-color-4 `none` keyword, `calc()` / `min()` / `max()` / `clamp()` in computed values, percentage line-height → px, and the border / flex / list-style / outline / place shorthands.

#### Accessibility (a11y)
- `Element#computed_role` (WAI-ARIA computed role) and `Element#computed_label` (accessible name), with `::before` / `::after` generated content folded into the name, plus `#computed_description`.
- An accessibility tree (`#accessibility_tree` / `#aria_tree`) and a Playwright-compatible ARIA snapshot (`#aria_snapshot`).
- Role-based queries: `find_by_role` / `all_by_role` / `has_role?`.

#### DOM — nodes & interfaces
- Passive listeners, `<details>` toggle, transient `MutationObserver`s, in-tree script execution, and the `readyState` lifecycle.
- `assignedSlot`, composed `getRootNode`, shadow-root mutations, and eager `<template>` migration.
- `new Text()` / `new Comment()` / `new DocumentFragment()` constructors; `Range#createContextualFragment`.
- Checkbox/radio click activation behaviour, `indeterminate`, and radio groups.
- `HTMLCanvasElement` with a 2D-context stub.
- `ProcessingInstruction` as a real backend-backed node; `new Document()` / `createDocument` backed by a real XML document.
- `DOMImplementation#hasFeature`, the WHATWG XML serialization algorithm for `XMLSerializer`, and `Event#immediatePropagationStopped`.
- Opt-in approximate geometry for `getBoundingClientRect` et al.

#### Interaction & browser layer
- A shared `Dommy::Interaction` layer with event synthesis; a unified `Resources` interface.
- `Session#visit` settles the page by default (`settle:` option); a `javascript:` session option.
- `text:` filter on `find` / `all`, `Regexp` support in `has_text?`, and `has_css?(text:)`.

### Changed
- **Backend:** Makiri (Lexbor, no libxml2) replaces nokolexbor and is now the default backend; the Nokogiri dependency is removed (Makiri only). Adopts Makiri's HTML/XML document split, with `DOMParser` XML routed to an XML document and CDATA wired through.
- **Dependency:** requires `makiri >= 0.5.1` (for the compiled-selector cache).
- Absent DOM properties now read as JS `undefined` (not `null`) for feature detection.
- A runaway timer callback no longer crashes the runtime (timeout interrupt).

#### Performance
- Index + cache for the `querySelector` hot path on large DOMs; pre-filtering of `querySelectorAll` candidates on the backend tree; querySelector subtree scoping and a sibling-chain fast path.
- `classList` token caching to speed up class-selector matching.
- CSSOM rule text scanned over bytes, not UTF-8 characters.
- The bridge caches the interface descriptor so new proxies skip `__rb_host_describe`.

### Fixed
- **Promises:** the host promise value is now Promises/A+ conformant, including adopting a thenable returned from a `.then` callback.
- **Events:** a throwing event listener (and a throwing observer callback) is isolated so it cannot escape dispatch; a blank `<iframe>` gets a real nested document and fires its `load` event asynchronously.
- **DOM:** `getElementById` matches the id literally (not as a CSS selector); a fragment-parsed `<script>` never executes; pre-insertion validity and WebIDL `Node` coercion on tree mutation; `compareDocumentPosition()`; `ol.start` / `li.value` use HTML integer parsing; correct `MutationObserver` `childList` records for fragments / `normalize` / `splitText` / `replaceChild`; `createElementNS` validation; a cached wrapper is rebuilt when the backend recycles a node identity; JS-defined custom elements no longer crash on wrap.
- **Fetch:** `Request#signal` is always exposed and forbidden response headers are stripped; fetch/XHR request URLs resolve against the document base.
- **Backend:** cross-document moves and template cloning made backend-agnostic for Makiri; case-sensitive `*AttributeNS` getters; element namespace derived from Lexbor.
- **Traversal:** a `NodeFilter`'s thrown value propagates out of the traversal, with a re-entrancy guard on the active flag.
- **CSS:** corrected selector matching, `var()` ordering, and CSSOM wiring per spec review; empty-substring attribute match and hsl/modern-rgb colors; custom-property cycle detection by SCC; `CSSStyleSheet` `addRule` / `removeRule` validation; an unset style property reads as `""` over the JS bridge.
- **Range:** `deleteContents` implemented per spec with a corrected boundary-point comparison.

## 0.8.1 — 2026-05-31

### Changed

- Declare `nokogiri` (`~> 1.19`) as a runtime dependency so the default backend is installed automatically; the `1.19` floor pulls in recent security fixes. Nokolexbor remains an opt-in alternative via `Dommy::Backend.use(:nokolexbor)`.

## 0.8.0 — 2026-05-31

A large WHATWG-conformance pass, focused on the Fetch surface, DOM traversal /
collections, selectors, encoding, and events.

### Added

#### Fetch — Response
- `new Response(body, init)` constructor, plus static `Response.json(data, init)`, `Response.redirect(url, status)`, and `Response.error()`
- `Response.type` (`"default"` / `"error"` / `"basic"`)
- `Response.body` is now a `ReadableStream` (or `null`); `Response.bodyUsed` tracks single consumption, and `text()` / `json()` / `arrayBuffer()` / `blob()` reject once the body has been read
- `Response.formData()` — parses an `application/x-www-form-urlencoded` or `multipart/form-data` body into a `FormData`
- Body extraction: a `Blob` / `File`, `URLSearchParams`, `FormData`, or `ArrayBuffer` / typed-array body is serialized to bytes with the matching default `Content-Type`

#### Fetch — Headers (WHATWG rewrite)
- Header names are stored lowercased; `keys()` / `values()` / `entries()` / `forEach()` iterate sorted, combining duplicate values with `", "`
- `Set-Cookie` is kept separate (never combined) and exposed via `getSetCookie()`
- Header name (token) and value (no NUL/CR/LF, whitespace-trimmed) validation, raising `TypeError`
- `new Headers(init)` accepts a record, a sequence of `[name, value]` pairs, or another `Headers`
- An immutable guard on the headers of `Response.error()` / `Response.redirect()`

#### Blob
- `Blob.text()` and `Blob.arrayBuffer()` now return `Promise`s (their spec return types)

#### DOM — Node & Document
- `Node#contains`, `isEqualNode`, `isSameNode`, `getRootNode`, `compareDocumentPosition`, and `lookupNamespaceURI` / `lookupPrefix` / `isDefaultNamespace`
- `DocumentType`, `ProcessingInstruction`, `CDATASection`, and `DOMImplementation` document factories
- `document.readyState` / `visibilityState` / `hidden` / `hasFocus()` and other document state getters; virtual `window` scroll properties

#### DOM — Traversal & collections
- `TreeWalker` and `NodeIterator` (`whatToShow`, `NodeFilter`, live-removal handling)
- `HTMLCollection`, `DOMStringMap`, and `NamedNodeMap` as WebIDL legacy platform objects (indexed + named properties); generalized `DOMTokenList`
- WICG `Observable` API (`Observable`, `Subscriber`, operators, `EventTarget.when`)

#### DOM — Selectors, parsing, encoding
- A CSS Selectors Level 4 grammar validator (invalid selectors raise a `SyntaxError`); `:scope`, `closest`
- `insertAdjacentHTML`, `outerHTML`, and XML parse/serialize via `DOMParser` / `XMLSerializer`
- `TextEncoder` / `TextDecoder` with typed-array marshalling, a WHATWG UTF-8 decoder, and `encodeInto`

#### Events, history, abort, ARIA
- WHATWG event propagation; a spec-compliant `WebSocket` with `MessageEvent` / `CloseEvent`; `PopStateEvent`
- `History` back/forward state restoration; a `SecurityError` for cross-origin `pushState` / `replaceState`
- `AbortController` / `AbortSignal` (`reason`, `timeout`, `throwIfAborted`)
- ARIA attribute reflection (`ariaXxx` ↔ `aria-xxx`) and element reflection

### Changed

- **Breaking:** `Response#arrayBuffer`, `Blob#arrayBuffer`, `FileReader#readAsArrayBuffer`, `XHR` `responseType: "arraybuffer"`, and `SubtleCrypto.digest` now resolve to a real `ArrayBuffer` — 0.7.0 had changed these to a byte `Array`.
- **Breaking:** `Headers` iteration is now lowercased and sorted (was Title-Case in insertion order).
- A `Response` `statusText` is validated against the reason-phrase grammar, and a null-body status (204/205/304) constructed with a body raises a `TypeError`.
- Requires Ruby >= 3.2.

### Fixed

- `MutationObserver` delivers records on the microtask queue and handles CharacterData / move records; `observe()` validates its options
- The URL parser throws a `TypeError` on parse failure and tolerates lone surrogates in JSON bodies
- `TextDecoder` strips a streaming BOM at the code-point level

## 0.7.0 — 2026-05-29

### Added

#### Queries & serialization
- XPath queries and document serialization helpers
- `:disabled` / `:enabled` / `:checked` CSS pseudo-classes in selector queries

#### URL
- WHATWG `URL.parse` / `URL.canParse` static methods

#### Document
- `document.origin` / `document.contentType`; `Location` origin now updates on absolute-URL navigation

#### FormData
- `multipart/form-data` encoding

#### CharacterData
- `ChildNode` mixin methods (`before` / `after` / `replaceWith` / `remove`) on `CharacterDataNode`

### Fixed

- `Headers#has` is now case-insensitive
- `Headers#forEach` passes the `Headers` object as the third callback argument
- `History.pushState` / `replaceState` now structured-clone the state argument
- `XHR.abort()` is a no-op when `OPENED` and the send() flag is unset
- `Event` dispatch resets `currentTarget` / `eventPhase` to their defaults afterward
- `Document.adoptNode` preserves node identity across documents
- `MutationObserver.observe()` replaces options on re-observation
- `CharacterDataNode#remove` and `Element#textContent=` now notify `MutationObserver`

### Changed

- **Breaking:** `Response#arrayBuffer` / `XHR` `responseType: "arraybuffer"` now resolve to a byte array (`Array<Integer>`), and `Response#blob` / `XHR` `responseType: "blob"` now resolve to a real `Dommy::Blob` (MIME type taken from the `Content-Type` header) — previously both returned the raw body string. Aligns with `FileReader` / `Blob`.
- Removed serialization from `FormData`
- Standardized gem-internal method naming conventions (`internal_` / `__test_` prefixes, JS-bridge dunder methods renamed)
- Added `__js_method_names__` to expose JS-bridge callable methods

## 0.6.0 — 2026-05-22

### Added

#### Layout-adjacent stubs
- `element.scrollIntoView` / `scrollTo` / `scrollBy` / `scroll` (no-op; calls recorded via `element.__scroll_log__` for test assertions)
- `element.scrollTop` / `scrollLeft` / `scrollWidth` / `scrollHeight` / `clientWidth` / `clientHeight` / `offsetWidth` / `offsetHeight` etc. — return 0
- `element.getClientRects` returns `[]`
- `window.getComputedStyle(el)` returns the element's inline `StyleDeclaration`

#### Popover API
- `element.showPopover` / `hidePopover` / `togglePopover`
- `popover` attribute, `beforetoggle` / `toggle` event firing with `{oldState, newState}` detail

#### Fullscreen API
- `element.requestFullscreen` / `document.exitFullscreen` / `document.fullscreenElement` / `document.fullscreenEnabled`
- `fullscreenchange` event

#### URLPattern
- `Dommy::URLPattern` (`/users/:id`, `/docs/*`, `:version+` modifier, etc.) — per-component pattern matching with named capture groups

#### View Transitions API
- `document.startViewTransition(callback)` returns a `ViewTransition` with all promises pre-resolved

#### Navigator extras
- `navigator.locks.request(name, callback)` / `query()` (Web Locks API)
- `navigator.storage.estimate()` / `persist()` / `persisted()` (StorageManager)

#### Crypto
- `crypto.subtle.encrypt` / `decrypt` (AES-GCM 128/256, with `additionalData` and `tagLength` options)

#### Original 0.6.0 additions:

#### SVG
- `Dommy::SVGElement` base + ~63 specialized subclasses covering shapes (`circle`/`rect`/`ellipse`/`line`/`polygon`/`polyline`/`path`), structure (`g`/`defs`/`symbol`/`use`/`image`/`foreignObject`), gradients (`linearGradient`/`radialGradient`/`stop`), filters (full set of standard primitives: Gaussian blur, offset, blend, color matrix, flood, composite, merge, component transfer, tile, morphology, image, drop shadow, turbulence, displacement map, convolve matrix, diffuse / specular lighting + light sources), marker / mask / pattern / clipPath, `<a>` / `<textPath>` / `<view>` / `<switch>` / `<metadata>`, and SMIL animation (`<animate>` / `<animateTransform>` / `<animateMotion>` / `<set>` / `<mpath>` / `<discard>`)
- Namespace-aware element dispatch — `<title>` inside `<head>` stays `HTMLTitleElement`, inside `<svg>` becomes `SVGTitleElement`
- Case-sensitive attribute round-trip for SVG (`viewBox`, `preserveAspectRatio`, etc.)

#### Web Animations API
- `Dommy::Animation` / `Dommy::KeyframeEffect` with full state machine (`idle` / `running` / `paused` / `finished`)
- `Element#animate(keyframes, options)` and `Element#get_animations`
- Auto-finish via scheduler (`advance_time`) and Promise integration (`animation.finished` / `animation.ready`)

#### Range / Selection
- `Dommy::Range` (boundary points, `compareBoundaryPoints`, `extractContents` / `cloneContents` / `surroundContents` / `deleteContents`, `intersectsNode` / `containsNode`, `toString`)
- `Dommy::Selection` (`document.get_selection`, `addRange`, `collapse`, `selectAllChildren`)
- Layout-dependent geometry returns zeroed rects

#### URL parsing (WHATWG-leaning)
- Unified `Dommy::URL` (the old `Dommy::Url` is removed)
- Input preprocessing: leading / trailing C0+space strip, embedded tab/LF/CR removal, special-scheme backslash → forward slash, percent-encoding of unsafe chars in path / query / fragment, `./` and `../` resolution, empty path → `/` for special schemes
- IPv4 number forms (`http://0x7f.1/`, `http://0177.0.0.1/`, `http://2130706433/`) normalize to dotted-decimal
- ws/wss default port stripping (`ws://h/` from `ws://h:80/`)
- `origin` follows the spec: tuple for http(s) / ws(s) / ftp, `"null"` for file / data / javascript, inner-URL origin for `blob:`
- Opaque-scheme body preservation (`javascript:alert(1)` keeps `alert(1)`, `mailto:` / `data:` / `tel:` / `blob:`)
- `url.search` exposes the raw query (preserves `%20`, stray `?`); `searchParams.toString()` still uses form-encoding (`+` for space)
- `hostname=` setter Punycode-encodes non-ASCII

#### IDNA (WHATWG complete)
- RFC 3492 Punycode encoder / decoder (`Dommy::Internal::Punycode`)
- UTS #46 IDNA ToASCII / ToUnicode (`Dommy::Internal::IDNA`) with WHATWG parameters (`UseSTD3ASCIIRules = false`, nontransitional)
- NFC normalization, Unicode case folding, UTS #46 mapping table, disallowed-character rejection
- RFC 5893 Bidi rules (all 6)
- RFC 5892 ContextJ (ZWJ / ZWNJ with Virama lookup)
- RFC 5892 ContextO (middle dot / Greek lower numeral sign / Hebrew geresh & gershayim / Katakana middle dot / mixed Arabic-Indic digits)
- Hyphen constraints, label-length cap (63 octets), domain-length cap (253 octets), leading combining mark rejection
- A-label / U-label validity (round-trip check, no-empty-intermediate, decoded U-label re-validation)
- Unicode 16.0 tables vendored under `vendor/unicode/`, regenerated via `script/build_idna_tables.rb`

#### Extended events
- `InputEvent` / `PointerEvent` / `ProgressEvent` / `DragEvent`
- `Touch` / `TouchList` / `TouchEvent` / `ClipboardEvent`
- `CompositionEvent` (IME) / `WheelEvent` (with `DOM_DELTA_*` constants)
- `FocusEvent` (`relatedTarget`) / `BeforeUnloadEvent` (`returnValue`)
- `MessageEvent` / `CloseEvent` / `CookieChangeEvent` / `MediaQueryListEvent`

#### Network / IO
- `XMLHttpRequest` (sync + async, full state machine, `responseType` decoding incl. JSON, shares `__fetchy_stub__` with `fetch`)
- `WebSocket` (test seams: `__simulate_open__` / `__simulate_message__` / `__simulate_close__` / `__simulate_error__`)
- `EventSource` (Server-Sent Events, `__simulate_message__(data, event: "...")`)
- `FileReader` (`readAsText` / `readAsDataURL` / `readAsArrayBuffer` / `readAsBinaryString`)
- `Streams` API: `ReadableStream` / `WritableStream` / `TransformStream`
- `TextEncoderStream` / `TextDecoderStream`
- `CompressionStream` / `DecompressionStream` (gzip / deflate / deflate-raw via Ruby `Zlib`)

#### Messaging
- `MessageChannel` / `MessagePort` (entangled ports with automatic `structuredClone` on transfer)
- `BroadcastChannel` (same-Window pub/sub)
- `Worker` (inline-emulated; test seams `__on_message__` / `__post_to_main__`)

#### Crypto
- `Dommy::Crypto` — `randomUUID` + `getRandomValues` (already in 0.5.0)
- `crypto.subtle.digest` (SHA-1 / SHA-256 / SHA-384 / SHA-512, RFC vectors verified)
- `crypto.subtle.generateKey` / `importKey` / `sign` / `verify` (HMAC, via OpenSSL)
- `CryptoKey` opaque handle

#### Storage / Cookies
- `cookieStore.get/getAll/set/delete` + `change` event (async Cookie Store API, backed by the same jar `document.cookie` uses)

#### Observers
- `IntersectionObserver` / `ResizeObserver` / `PerformanceObserver` (test-driven via `__trigger__(entries)`)

#### Navigator
- `navigator.geolocation` (`__set_position__` / `__set_error__` test seams)
- `navigator.share(data)` / `canShare(data)` (records last shared payload)
- `navigator.vibrate(pattern)` (records pattern log)
- `navigator.wakeLock.request(type)` → `WakeLockSentinel`
- `navigator.getBattery()` → `BatteryManager`

#### Scheduling / Performance
- `window.matchMedia(query)` → `MediaQueryList` (`__set_matches__` flips and fires `change`)
- `requestIdleCallback` / `cancelIdleCallback`
- `structuredClone` (global)
- `performance.mark` / `measure` / `getEntriesByName` / `getEntriesByType` / `clearMarks` / `clearMeasures`

#### Misc
- `Notification` with class-level `__set_permission__`
- `TextEncoder` / `TextDecoder` (UTF-8 / UTF-16 / ISO-8859-1)
- `Dommy.structured_clone` deep clone for primitives, Array, Hash, Set, DOM nodes (via `cloneNode`)

### Changed

- File renames to match class names: `world.rb` → `window.rb`, `observer.rb` → `mutation_observer.rb`
- File splits: `router.rb` → `location.rb` + `history.rb`, `observers.rb` → `intersection_observer.rb` + `resize_observer.rb` + `performance_observer.rb`
- `Internal::ObservableCallback` mixin shared across the three observer classes
- `Internal::RangeTextSerializer` collaborator extracted from `Range#to_s`
- `Range#compare_points` split into three topology-case helpers (`compare_offset_to_branch` / `compare_branch_to_offset` / `compare_via_lca`)

### Fixed

- `Dommy::URL.new("javascript:alert(1)").href` now returns `"javascript:alert(1)"` (previously dropped the body)
- `url.search` no longer round-trips through URLSearchParams (preserves `%20`, stray `?`)
- `Range#common_ancestor_container` now finds the deepest common ancestor
- `Internal::DomMatching` `when Range` now correctly references Ruby's `::Range` instead of `Dommy::Range`

## 0.5.0 — 2026-05-21

Initial release.
