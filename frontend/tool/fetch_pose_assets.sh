#!/usr/bin/env bash
# Downloads the pose tracker into web/pose/, so the app can start a session
# without the internet (and without waiting for a slow connection).
#
#   tool/fetch_pose_assets.sh
#
# Run it once, then build or run the web app as usual. Without these files the
# app loads the same things from jsDelivr and Google's servers every time a
# session opens, as before.
#
# What it fetches (about 25 MB, kept out of the repository):
#   MediaPipe Tasks Vision 0.10.14, runtime and WebAssembly  (Apache-2.0)
#   pose_landmarker_lite, the pose model                     (Apache-2.0)
# The versions must stay the ones named in web/pose_bridge.js.
set -euo pipefail
cd "$(dirname "$0")/../web"

vision="https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@0.10.14"
model="https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task"

mkdir -p pose/wasm
fetch() {  # url, file
  if [[ -s "pose/$2" ]]; then
    echo "  $2 (already here)"
    return
  fi
  echo "  $2"
  # To a temporary name first, so a download that stops half-way is never
  # mistaken for the file; running this again carries on where it stopped.
  curl -fsSL -C - --retry 8 --retry-delay 3 --retry-all-errors -o "pose/$2.part" "$1"
  mv "pose/$2.part" "pose/$2"
}

echo "Downloading the pose tracker into web/pose/ ..."
fetch "$vision/vision_bundle.mjs" vision_bundle.mjs
for name in vision_wasm_internal vision_wasm_nosimd_internal; do
  fetch "$vision/wasm/$name.js" "wasm/$name.js"
  fetch "$vision/wasm/$name.wasm" "wasm/$name.wasm"
done
fetch "$model" pose_landmarker_lite.task

# Written last: the app uses the local copy only when this file is there, so
# an interrupted download is never used.
cat > pose/manifest.json <<EOF
{
  "tasks_vision": "0.10.14",
  "model": "pose_landmarker_lite/float16/1",
  "files": ["vision_bundle.mjs", "wasm/", "pose_landmarker_lite.task"]
}
EOF
du -sh pose | sed 's/^/Done: /'
