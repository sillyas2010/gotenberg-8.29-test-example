#!/usr/bin/env bash
#
# Reproduce the Gotenberg 8.29+ print-emulation regression.
#
# Produces four PDFs in ./out:
#
#   out/good-vanilla.pdf      Gotenberg 8.28.0, plain test.html            -> all three items GREEN
#   out/bad-vanilla.pdf       Gotenberg 8.29.0, plain test.html            -> all three items RED
#   out/good-workaround.pdf   Gotenberg 8.28.0, test-with-workaround.html  -> all three items GREEN
#   out/bad-workaround.pdf    Gotenberg 8.29.0, test-with-workaround.html  -> all three items GREEN (workaround restores behaviour)
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
  curl --silent --show-error --fail \
    --request POST "$url" \
    --form "files=@${html};filename=index.html" \
    --form "emulatedMediaType=print" \
    --form 'waitForExpression=!!document.body.getAttribute("data-pdf-ready")' \
    -o "$out"
}

echo
echo "== Gotenberg 8.28.0 (expected: all three items GREEN) =="
convert "$GOOD_URL" test.html               out/good-vanilla.pdf
convert "$GOOD_URL" test-with-workaround.html out/good-workaround.pdf

echo
echo "== Gotenberg 8.29.0 (expected: all three items RED in vanilla, GREEN with workaround) =="
convert "$BAD_URL"  test.html               out/bad-vanilla.pdf
convert "$BAD_URL"  test-with-workaround.html out/bad-workaround.pdf

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
  echo "  good-vanilla.pdf       -> three FIRED lines (8.28.0 works)"
  echo "  bad-vanilla.pdf        -> three NEVER FIRED lines (8.29.0 regression)"
  echo "  good-workaround.pdf    -> three FIRED lines (workaround is a no-op on the good build)"
  echo "  bad-workaround.pdf     -> three FIRED lines (workaround restores behaviour on the bad build)"
else
  echo
  echo "Install pdftotext (brew install poppler) to auto-extract the test-result lines."
fi
