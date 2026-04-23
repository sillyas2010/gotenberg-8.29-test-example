# Gotenberg 8.29+ print-emulation regression &mdash; minimal reproduction

This directory contains a self-contained reproduction of the regression where
`requestAnimationFrame`, `ResizeObserver` and `IntersectionObserver` silently
stop working with
`POST /forms/chromium/convert/html` on Gotenberg `8.29.0` and later.

## Files

| File | Purpose |
|---|---|
| `test.html` | The reproduction from the issue report: three rows (rAF / `ResizeObserver` / `IntersectionObserver`). Sets `data-pdf-ready` on `<body>` after 3s so Gotenberg knows when to snapshot. |
| `test-with-workaround.html` | Same page, but patches `requestAnimationFrame`, `ResizeObserver` and `IntersectionObserver` before any other script runs. Demonstrates that the workaround restores behaviour. |
| `docker-compose.yml` | Runs two Gotenberg instances side by side &mdash; `8.28.0` (last good) on port `3028`, `8.29.0` (first affected) on port `3029`. |
| `reproduce.sh` | Drives both Gotenberg endpoints with both HTML files, writes four PDFs into `./out`, and (if `pdftotext` is installed) prints the test-result lines extracted from each PDF. |

## Run it

```bash
docker compose up -d
./reproduce.sh
docker compose down
```

## Expected results

Open each PDF in `./out`:

Observed result (confirmed locally):

| Row | `good-vanilla.pdf` (8.28.0) | `bad-vanilla.pdf` (8.29.0) | `good-workaround.pdf` | `bad-workaround.pdf` |
|---|---|---|---|---|
| `requestAnimationFrame` | FIRED | **NEVER FIRED** | FIRED | FIRED |
| `ResizeObserver` | FIRED (width=300) | **NEVER FIRED** | FIRED | FIRED |
| `IntersectionObserver` | FIRED | **NEVER FIRED** | FIRED | FIRED |

The three paint-driven APIs &mdash; rAF, `ResizeObserver`, `IntersectionObserver`
&mdash; are definitively broken on 8.29.0, and the polyfills in
`test-with-workaround.html` fully restore them.

## Real-world impact

`@visx/responsive`&rsquo;s `ParentSize` wraps its `ResizeObserver` entry in
`requestAnimationFrame` before forwarding measured `width` / `height` to
children. With both broken, `ParentSize` reports `width = 0` forever, every
SVG chart renders at 0&nbsp;&times;&nbsp;0, and the resulting PDF contains
blank rectangles where charts should be.
