# BLisp web target

The web target is intended to let an application be authored entirely in BLisp source. Generated HTML, CSS, JavaScript bootstrap code, bytecode, and WebAssembly are build artifacts rather than source-language requirements.

The detailed implementation roadmap is tracked in [issue #15](https://github.com/not-the-ccp/blisp/issues/15).

## Architecture

The browser is a host for the same BLisp language, not a separate `BLisp-Web` dialect.

```text
.bl/.blx
   -> common frontend / expansion / core IR
   -> BLisp bytecode
   -> portable BLisp VM
        -> native host
        -> browser/Wasm host
```

Browser APIs enter through host capabilities. Core values, closures, prototypes, errors, modules, iteration, bytecode, and GC semantics do not change for the web target.

The UI layer uses real HTML DOM and CSS. BLisp does not replace browser layout, accessibility, text selection, forms, developer tools, or the Web Platform with a canvas-only widget system.

## Host-neutral HTML values

`lib/web/html.blx` defines ordinary BLisp values representing text, elements, fragments, and attributes. They are intentionally independent of a DOM implementation so both build-time rendering and a future live browser renderer can consume the same tree.

```blx
include "lib/web.blx";

let h = web.html;

let page = h.main(
  {class: "shell"},
  h.h1("Hello from BLisp"),
  h.p("Text is escaped by default."),
  h.a({href: "/about", aria_label: "About"}, "About")
);

println(h.render(page));
```

Object attribute names use `_` as a source-friendly spelling for `-`, so `aria_label` serializes as `aria-label`. `html.attr(name, value)` and `html.attrs(...)` preserve exact names when required.

Strings and other ordinary child values become escaped text. Arrays are flattened as child sequences and `nil` children are omitted. `html.unsafeRaw()` is an explicit escape hatch for already-trusted markup; normal application data should not use it.

Boolean HTML attributes use ordinary BLisp booleans: `true` emits the attribute without a value, while `false` and `nil` omit it.

## Structured CSS

`lib/web/css.blx` represents declarations, rules, and stylesheets as ordinary BLisp values and serializes real CSS.

```blx
let css = web.css;

let styles = css.sheet(
  css.rule("body", {
    margin: "0",
    font_family: "system-ui, sans-serif"
  }),
  css.rule(".card", {
    border_radius: "1rem"
  })
);

println(css.render(styles));
```

Object property names also translate `_` to `-`. Exact property names, including CSS custom properties, use `css.prop()`:

```blx
css.props(
  css.prop("--accent", "#83b"),
  css.prop("color", "var(--accent)")
)
```

Ordinary values may not contain `;`, `{`, or `}` so accidental data cannot break out of a declaration. `css.raw()` is available for deliberately authored trusted CSS values that require such syntax.

## Static documents

`web.static.page()` renders a complete HTML document using the same HTML values:

```blx
let document = web.static.page({
  lang: "en",
  title: "Example",
  stylesheet: "app.css",
  body: h.main(
    h.h1("A website authored in BLisp")
  )
});
```

A static site can therefore be emitted without shipping a BLisp runtime to the browser. The later live DOM renderer will use the same host-neutral tree instead of introducing a second template language.

See `examples/web_static.blx` for a complete initial example.

## Next layers

The current library is the W0 foundation from issue #15. The next web-specific runtime work begins after the portable VM can target WebAssembly: a small host ABI, raw DOM/browser capabilities, a live DOM renderer, fine-grained reactive state, browser async bridging, and `blisp web build` / `blisp web dev` tooling.
