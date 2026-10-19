#!/bin/bash
# Adds the ElevenLabs voice-over (and optional music) to a rendered intro.
#   video/mux.sh ar voice-ar.mp3              → website/assets/video/coshare-intro-ar.mp4
#   video/mux.sh en voice-en.mp3 music.mp3    → music ducks automatically under the voice
set -euo pipefail
cd "$(dirname "$0")/.."
LANG_CODE="${1:?usage: video/mux.sh <ar|en> <voice.mp3> [music.mp3]}"
VOICE="${2:?voice file missing}"
MUSIC="${3:-}"
MASTER="video/out/coshare-intro-$LANG_CODE-silent.mp4"
OUT="website/assets/video/coshare-intro-$LANG_CODE.mp4"
[ -f "$MASTER" ] || { echo "Render first: video/render.sh $LANG_CODE"; exit 1; }

LENGTH=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MASTER")
FADE_AT=$(python3 -c "print(max(0, $LENGTH - 1.5))")

if [ -n "$MUSIC" ]; then
  # Voice at full level; music at about -18 dB and pushed down further while the voice speaks.
  ffmpeg -y -loglevel error -i "$MASTER" -i "$VOICE" -stream_loop -1 -i "$MUSIC" -filter_complex \
    "[1:a]aresample=48000,apad[voice];[voice]asplit=2[v1][v2];\
     [2:a]aresample=48000,volume=0.13[music];\
     [music][v1]sidechaincompress=threshold=0.03:ratio=8:attack=20:release=400[ducked];\
     [ducked][v2]amix=inputs=2:duration=first:normalize=0,afade=t=out:st=${FADE_AT}:d=1.5[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT"
else
  ffmpeg -y -loglevel error -i "$MASTER" -i "$VOICE" -filter_complex "[1:a]aresample=48000,apad[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart "$OUT"
fi
echo "✓ $OUT"
