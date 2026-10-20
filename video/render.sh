#!/bin/bash
# Renders the CoShare intro (Arabic + English) to MP4 and makes posters for the website.
# (The site's social image, website/assets/og-image.png, is designed separately and left alone.)
#   video/render.sh            → both languages
#   video/render.sh en         → one language
# Needs ffmpeg (brew install ffmpeg). Add the ElevenLabs voice-over afterwards with video/mux.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/website/assets/video"
mkdir -p "$OUT" build/tools

# Rebuild the animation page from its template + the shared icon set.
python3 - <<'PY'
t = open("video/animation/template.html").read()
icons = open("video/animation/icons.svg.html").read()
open("video/animation/index.html", "w").write(t.replace("<!--ICONS-->", icons))
PY

xcrun swiftc -O -swift-version 5 -sdk "$(xcrun --show-sdk-path --sdk macosx)" video/render/Render.swift -o build/tools/Render

PORT=8799
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null || true' EXIT
sleep 1

mkdir -p video/out
for LANG_CODE in ${1:-ar en}; do
  # Narration timing (video/voice/timings.json): retimes the scenes to the voice-over.
  KEYS=$(python3 -c "import json;k=json.load(open('video/voice/timings.json'))['${LANG_CODE}']['keys'];print(','.join(f'{a}:{v}' for a,v in k))")
  LENGTH=$(python3 -c "import json;print(json.load(open('video/voice/timings.json'))['${LANG_CODE}']['keys'][-1][1])")
  VOICE=$(python3 -c "import json;print(json.load(open('video/voice/timings.json'))['${LANG_CODE}']['voice'])")
  URL="http://127.0.0.1:$PORT/video/animation/index.html?lang=${LANG_CODE}&render=1&keys=${KEYS}"
  echo "• Rendering ${LANG_CODE} (${LENGTH}s)..."
  build/tools/Render "$URL" "video/out/coshare-intro-${LANG_CODE}-silent.mp4" --duration "$LENGTH"
  build/tools/Render "http://127.0.0.1:$PORT/video/animation/index.html?lang=${LANG_CODE}&render=1" --still 22.6 "$OUT/poster-${LANG_CODE}.jpg"
  if [ -f "$VOICE" ]; then
    video/mux.sh "$LANG_CODE" "$VOICE"
  else
    cp "video/out/coshare-intro-${LANG_CODE}-silent.mp4" "$OUT/coshare-intro-${LANG_CODE}.mp4"
  fi
done

echo "✓ Done: $OUT"
ls -lh "$OUT"
