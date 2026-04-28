# Gotenberg 8.29+ print-emulation regression &mdash; minimal reproduction

This directory contains a self-contained reproduction of the regression where
`requestAnimationFrame`, `ResizeObserver`, `IntersectionObserver` &mdash; and,
transitively, anything built on top of them, including the **Google Maps JS
API** &mdash; silently stop working with
`POST /forms/chromium/convert/html` on Gotenberg `8.29.0` and later.

## Files

| File | Purpose |
|---|---|
| `test.html` | The reproduction from the issue report. Tests `requestAnimationFrame`, `ResizeObserver`, `IntersectionObserver`, plus a battery of paint-pipeline-adjacent diagnostics &mdash; `MutationObserver` (control), CSS `transitionend`, CSS `animationend`, `createImageBitmap()`, `requestIdleCallback`, and a WebGL `clear` + `readPixels` round-trip &mdash; and every Google Maps Map-instance event that matters for PDF generation: `tilesloaded`, `idle`, `bounds_changed`, `projection_changed` (fire automatically during initial render) plus `center_changed` and `zoom_changed` (driven explicitly via `setCenter` / `setZoom` after init, since otherwise they never fire on a freshly constructed map). Pointer / drag / mouse / heading / tilt / context-menu events are excluded because they require user input or 3D mode and never fire in a headless PDF render. Sets `data-pdf-ready` on `<body>` after 8s so Gotenberg knows when to snapshot. |
| `test-with-workaround.html` | Same page (incl. the diagnostic battery), but patches `requestAnimationFrame`, `ResizeObserver` and `IntersectionObserver` before any other script runs. Restores the three primitives and most Google Maps events on 8.29.0 &mdash; with one residual hole: `tilesloaded` still never fires, meaning Maps never reports that its tiles have actually painted. The diagnostic rows make it possible to read off, from one PDF, exactly which paint-adjacent surfaces the polyfill does and does not rescue. |
| `docker-compose.yml` | Runs two Gotenberg instances side by side &mdash; `8.28.0` (last good) on port `3028`, `8.29.0` (first affected) on port `3029`. |
| `reproduce.sh` | Loads `GOOGLE_MAPS_API_KEY` from `.env`, renders the templated HTML, drives both Gotenberg endpoints with both HTML files, writes four PDFs into `./out`, and (if `pdftotext` is installed) prints the test-result lines extracted from each PDF. |
| `.env` | Holds `GOOGLE_MAPS_API_KEY="AIza..."`. Required for the Google Maps row to render. Not committed. |

## Run it

```bash
echo 'GOOGLE_MAPS_API_KEY="AIza..."' > .env   # one-time, must allow file:// / null Referer
docker compose up -d
./reproduce.sh
docker compose down
```

> **Note on the API key.** Gotenberg loads the uploaded HTML via `file://`, so
> outbound requests carry an empty/`null` Origin and Referer. The Maps key in
> `.env` therefore needs either no HTTP-referrer restriction or a restriction
> permissive enough to allow that. If the key is misconfigured, you'll see
> `gm_authFailure` and "Oops! Something went wrong." in every PDF, including
> the 8.28.0 ones &mdash; that means the test did not actually exercise Maps.

## Expected results

Open each PDF in `./out`:

Observed result (confirmed locally on this repo, including the
paint-pipeline-adjacent diagnostic battery):

| Row | `good-vanilla.pdf` (8.28.0) | `bad-vanilla.pdf` (8.29.0) | `good-workaround.pdf` | `bad-workaround.pdf` |
|---|---|---|---|---|
| `requestAnimationFrame` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| `ResizeObserver` | FIRED (width=300) | **NEVER FIRED** | FIRED | FIRED |
| `IntersectionObserver` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| `MutationObserver` (control) | FIRED | FIRED | FIRED | FIRED |
| CSS `transitionend` | FIRED | **NEVER FIRED** | FIRED | **NEVER FIRED** |
| CSS `animationend` | FIRED | **NEVER FIRED** | FIRED | **NEVER FIRED** |
| `createImageBitmap()` | FIRED | FIRED | FIRED | FIRED |
| `requestIdleCallback` | FIRED | FIRED | FIRED | FIRED |
| WebGL `clear` + `readPixels` | FIRED (RGBA[0]=255) | FIRED (RGBA[0]=255) | FIRED | FIRED |
| Google Maps `tilesloaded` | FIRED | **NEVER FIRED** | FIRED | **NEVER FIRED** |
| Google Maps `idle` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| Google Maps `bounds_changed` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| Google Maps `projection_changed` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| Google Maps `center_changed` (post-init) | FIRED | FIRED | FIRED | FIRED |
| Google Maps `zoom_changed` (post-init) | FIRED | FIRED | FIRED | FIRED |

The three paint-driven primitives &mdash; rAF, `ResizeObserver`,
`IntersectionObserver` &mdash; are definitively broken on 8.29.0 vanilla, and
Google Maps inherits the breakage. Looking row-by-row at the Maps events makes
the failure mode much more precise:

- **Paint-driven Maps events** &mdash; `tilesloaded`, `idle`, `bounds_changed`,
  `projection_changed` &mdash; fire as the tile pipeline progresses and depend
  on the same paint surfaces the regression breaks. All four are RED on
  `bad-vanilla.pdf`. The rAF / `ResizeObserver` / `IntersectionObserver`
  polyfills in `test-with-workaround.html` are enough to recover three of them
  (`idle`, `bounds_changed`, `projection_changed`) but **not `tilesloaded`**:
  on 8.29.0 the map never confirms that its tiles have actually painted, even
  with the workaround applied. The 99&nbsp;KB / 100&nbsp;KB sizes of
  `bad-vanilla.pdf` and `bad-workaround.pdf` &mdash; vs. ~190&nbsp;KB for the
  good PDFs &mdash; corroborate this: there are no map tiles in the bytes,
  only an empty grey rectangle.
- **Mutation-driven Maps events** &mdash; `center_changed`, `zoom_changed`
  &mdash; are driven synchronously by `setCenter` / `setZoom` after init and
  do **not** depend on the paint pipeline. The regression does not touch them:
  they fire on every build, including `bad-vanilla.pdf`. This is the cleanest
  signal that the 8.29.0 break is specifically about Chromium paint-pipeline
  surfaces, not about JavaScript event dispatch in general.

### What the diagnostic rows narrow the regression down to

The seven extra rows are designed to discriminate between three competing
explanations for the 8.29.0 break: (a) the entire compositor pipeline is
suspended, (b) only the JS-side animation-frame callback loop is suspended,
or (c) some narrower mix. The measured outcomes pick (b), with one nuance.

| Diagnostic | Family | 8.29.0 result | What it tells us |
|---|---|---|---|
| `MutationObserver` | microtask queue | FIRED | Microtask path is unaffected. Confirms the regression is not a generic "JS callbacks stop firing" bug. |
| CSS `transitionend` | animation-frame loop | NEVER FIRED | Same loop as rAF. Broken in lockstep, even with the rAF polyfill applied. |
| CSS `animationend` | animation-frame loop | NEVER FIRED | Same. The setTimeout-backed rAF polyfill does not drive CSS animation progress &mdash; that lives below the JS boundary, in Chromium itself. |
| `createImageBitmap()` | off-thread image decode | FIRED | Off-thread image decode IS alive on 8.29.0. Rules out "all image decode pipelines are dead". |
| `requestIdleCallback` | task queue, scheduled around frames | FIRED | rIC schedules off the task queue, not the BeginFrame loop, in this Chromium build. Independent of the rAF break. |
| WebGL `clear` + `readPixels` | GPU command buffer | FIRED, RGBA[0]=255 | The GL command stream and synchronous readback work fine. The compositor is not globally frozen &mdash; only the JS-visible frame-driven callback loop is. |

Two important consequences fall out of that table:

1. The 8.29.0 regression is **not** a wholesale "compositor suspended" failure
   as the original hypothesis suggested. WebGL renders, off-thread image
   decode resolves, requestIdleCallback fires, microtasks fire. The break is
   specifically the **animation-frame callback dispatch loop** that drives
   `requestAnimationFrame`, `ResizeObserver`, `IntersectionObserver`, CSS
   `transitionend` and CSS `animationend`. Anything keyed to that loop dies;
   anything keyed to other dispatch sources is unaffected.
2. The reason the rAF / RO / IO polyfills cannot fully rescue Google Maps on
   8.29.0 is now visible in one row: CSS `transitionend` is still NEVER FIRED
   in `bad-workaround.pdf`. Google Maps fades each tile in via a CSS opacity
   transition and uses the resulting `transitionend` to flip that tile to
   "ready"; without `transitionend` the per-tile readiness signal never
   arrives, and `tilesloaded` (which is gated on every visible tile reporting
   ready) cannot fire either &mdash; even though `idle`, `bounds_changed` and
   `projection_changed`, which are bookkeeping-only, do recover under the
   polyfill. So the residual `tilesloaded` hole is not mysterious: it is a
   direct consequence of CSS transitions being part of the same broken
   dispatch loop, which no JS polyfill can patch from inside the page.

Practical consequence for PDF generation: switching the ready-signal from
`tilesloaded` to `idle` lets the workaround unblock the JS-side `data-pdf-ready`
flag on 8.29.0, but the resulting PDF still contains an empty map &mdash; the
actual tiles never paint. There is no purely client-side workaround that
restores Maps tile rendering on 8.29.0; the regression has to be fixed in
Gotenberg / Chromium itself, specifically in whatever change disabled the
animation-frame callback dispatch loop under `emulatedMediaType=print`.

## Real-world impact

`@visx/responsive`&rsquo;s `ParentSize` wraps its `ResizeObserver` entry in
`requestAnimationFrame` before forwarding measured `width` / `height` to
children. With both broken, `ParentSize` reports `width = 0` forever, every
SVG chart renders at 0&nbsp;&times;&nbsp;0, and the resulting PDF contains
blank rectangles where charts should be.
