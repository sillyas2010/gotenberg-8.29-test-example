#!/usr/bin/env bash
#
# Reproduce the Gotenberg 8.29+ print-emulation regression.
#
# Produces four PDFs in ./out:
#
#   out/good-vanilla.pdf      Gotenberg 8.28.0, plain test.html            -> all rows GREEN
#   out/bad-vanilla.pdf       Gotenberg 8.29.0, plain test.html            -> primitive + Maps rows RED
#   out/good-workaround.pdf   Gotenberg 8.28.0, test-with-workaround.html  -> all rows GREEN
#   out/bad-workaround.pdf    Gotenberg 8.29.0, test-with-workaround.html  -> primitives GREEN (Maps still depends on additional broken paint surfaces)
#
# The rows under test are:
#   - requestAnimationFrame
#   - ResizeObserver
#   - IntersectionObserver
#   - Google Maps events that fire automatically during initial render and
#     therefore matter for PDF generation: tilesloaded, idle, bounds_changed,
#     center_changed, zoom_changed, projection_changed. Pointer / drag /
#     heading / tilt events are intentionally excluded - they require user
#     input or 3D mode and never fire in a headless PDF render.
#
# Google Maps requires GOOGLE_MAPS_API_KEY in .env.
#
# Usage:
#   docker compose up -d
#   ./reproduce.sh
#   docker compose down
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

mkdir -p out

# Load GOOGLE_MAPS_API_KEY (and any other vars) from .env if present, so we can
# render the Google Maps script tag before uploading the HTML to Gotenberg.
if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

if [ -z "${GOOGLE_MAPS_API_KEY:-}" ]; then
  echo "ERROR: GOOGLE_MAPS_API_KEY is not set. Add it to .env (e.g. GOOGLE_MAPS_API_KEY=\"AIza...\")." >&2
  exit 1
fi

# Render the templated HTML files (with __GOOGLE_MAPS_API_KEY__ substituted)
# into a per-run temp dir that we clean up on exit.
RENDER_DIR="$(mktemp -d -t gotenberg-repro.XXXXXX)"
trap 'rm -rf "$RENDER_DIR"' EXIT

render_html() {
  local src="$1"
  local dst="$RENDER_DIR/$(basename "$src")"
  sed -e "s|__GOOGLE_MAPS_API_KEY__|${GOOGLE_MAPS_API_KEY}|g" "$src" > "$dst"
  echo "$dst"
}

GOOD_URL="http://localhost:3028/forms/chromium/convert/html"
BAD_URL="http://localhost:3029/forms/chromium/convert/html"

wait_ready() {
  local url="$1"
  local name="$2"
  echo "Waiting for $name at $url ..."
  for _ in $(seq 1 60); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      echo "  $name is ready."
      return 0
    fi
    sleep 1
  done
  echo "ERROR: $name did not become ready in 60s." >&2
  exit 1
}

wait_ready "http://localhost:3028/health" "gotenberg-good (8.28.0)"
wait_ready "http://localhost:3029/health" "gotenberg-bad  (8.29.0)"

convert() {
  local url="$1"
  local html="$2"
  local out="$3"
  echo "  -> $out"
  # Gotenberg requires the uploaded HTML to be named 'index.html'; override
  # the multipart filename via curl's ;filename= helper so we can keep
  # descriptive names on disk.
  # Note: skipNetworkAlmostIdleEvent=true is required because, on 8.29.0,
  # Google Maps gets stuck retrying internal work forever (rAF is broken), so
  # "network almost idle" never triggers and the request would otherwise hit
  # api-timeout. The waitForExpression below is our authoritative ready signal.
  curl --silent --show-error --fail \
    --request POST "$url" \
    --form "files=@${html};filename=index.html" \
    --form "emulatedMediaType=print" \
    --form "skipNetworkAlmostIdleEvent=true" \
    --form 'waitForExpression=!!document.body.getAttribute("data-pdf-ready")' \
    -o "$out"
}

VANILLA_HTML="$(render_html test.html)"
WORKAROUND_HTML="$(render_html test-with-workaround.html)"

echo
echo "== Gotenberg 8.28.0 (expected: all rows GREEN) =="
convert "$GOOD_URL" "$VANILLA_HTML"    out/good-vanilla.pdf
convert "$GOOD_URL" "$WORKAROUND_HTML" out/good-workaround.pdf

echo
echo "== Gotenberg 8.29.0 (expected: primitive + Maps rows RED in vanilla; primitives GREEN with workaround, Maps still RED) =="
convert "$BAD_URL"  "$VANILLA_HTML"    out/bad-vanilla.pdf
convert "$BAD_URL"  "$WORKAROUND_HTML" out/bad-workaround.pdf

echo
echo "Done. Inspect the four PDFs in ./out to see the regression:"
ls -lh out/

if command -v pdftotext >/dev/null 2>&1; then
  echo
  echo "== Extracted test-result lines from each PDF (via pdftotext) =="
  for f in good-vanilla.pdf bad-vanilla.pdf good-workaround.pdf bad-workaround.pdf; do
    echo
    echo "--- out/$f ---"
    pdftotext "out/$f" - | grep -E 'FIRED|PENDING' || echo "(no matching lines)"
  done
  echo
  echo "Expected:"
  echo "  good-vanilla.pdf       -> every row FIRED (8.28.0 works)"
  echo "  bad-vanilla.pdf        -> primitive + Maps rows NEVER FIRED (8.29.0 regression)"
  echo "  good-workaround.pdf    -> every row FIRED (workaround is a no-op on the good build)"
  echo "  bad-workaround.pdf     -> primitives FIRED, Google Maps rows still NEVER FIRED (rAF/RO/IO polyfills do not cover every paint surface Maps needs)"
else
  echo
  echo "Install pdftotext (brew install poppler) to auto-extract the test-result lines."
fi
