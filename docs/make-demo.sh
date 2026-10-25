#!/bin/zsh
# Rebuild docs/demo.gif from the app's real HUD (off-screen; nothing on your screen is captured).
#   ./docs/make-demo.sh [path/to/Sasarisa.app]
set -e
cd "${0:a:h}/.."
APP=${1:-build-local/Sasarisa.app}
LANGUAGE=${2:-ko}                        # ./docs/make-demo.sh <app> en → docs/demo-en.gif (English README)
OUT=docs/demo.gif; [[ $LANGUAGE == en ]] && OUT=docs/demo-en.gif
D=$(mktemp -d)
"$APP/Contents/MacOS/${${APP:t}:r}" --demo-frames "$D" $LANGUAGE
# timing: title 1.6 s, then per scene: listening 0.7 s, result 1.7 s. The GIF is written by ImageIO with a delay per
# frame (ffmpeg 9's concat durations and palette filters showed only the last scene — 10/25).
ARGS=()
for f in $D/f*.png; do
  n=${${f:t:r}#f}; n=$((10#$n))
  d=1.7; (( n == 0 )) && d=1.6; (( n > 0 && n % 2 == 1 )) && d=0.7
  ARGS+=("$f:$d")
done
swift docs/make-gif.swift $OUT 960 $ARGS
[[ $LANGUAGE == en ]] || ffmpeg -loglevel error -y -i $D/f002.png -vf "scale=1280:-1" docs/demo-still.png
rm -rf $D
ls -la $OUT
