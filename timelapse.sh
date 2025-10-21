#!/bin/bash
set -e
export TZ="America/Halifax"

# ---- Secrets ----
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

# ---- Compute the target month = previous month (local time) ----
TARGET_MONTH=$(date -d "last month" +%Y-%m)
REMOTE_DIR="/WeatherCam/${TARGET_MONTH}"
OUT_MP4="timelapse_${TARGET_MONTH}.mp4"

echo "🎯 Building timelapse for ${TARGET_MONTH}"

# ---- Dropbox OAuth2 (refresh -> access token) ----
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# ---- Helper: list all JPG paths in the monthly folder (with pagination) ----
echo "📄 Listing JPEGs in ${REMOTE_DIR}..."
CURSOR=""
TMP_LIST_RESP=$(mktemp)
> filelist.txt

# First page
curl -s -X POST https://api.dropboxapi.com/2/files/list_folder \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Content-Type: application/json" \
  --data "{\"path\": \"${REMOTE_DIR}\", \"recursive\": false}" > "$TMP_LIST_RESP"

jq -r '.entries[] | select(.name | endswith(".jpg")) | .path_display' "$TMP_LIST_RESP" >> filelist.txt
HAS_MORE=$(jq -r '.has_more' "$TMP_LIST_RESP")
CURSOR=$(jq -r '.cursor // empty' "$TMP_LIST_RESP")

# Continue pages if needed
while [ "$HAS_MORE" = "true" ] && [ -n "$CURSOR" ]; do
  curl -s -X POST https://api.dropboxapi.com/2/files/list_folder/continue \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Content-Type: application/json" \
    --data "{\"cursor\": \"${CURSOR}\"}" > "$TMP_LIST_RESP"
  jq -r '.entries[] | select(.name | endswith(".jpg")) | .path_display' "$TMP_LIST_RESP" >> filelist.txt
  HAS_MORE=$(jq -r '.has_more' "$TMP_LIST_RESP")
  CURSOR=$(jq -r '.cursor // empty' "$TMP_LIST_RESP")
done

# Sort lexicographically (YYYYMMDD_HHMMSS.jpg sorts chronologically)
sort -o filelist.txt filelist.txt

COUNT=$(wc -l < filelist.txt | tr -d ' ')
echo "🖼  Found ${COUNT} images"
if [ "$COUNT" -lt 2 ]; then
  echo "⚠️  Not enough images for a timelapse. Exiting."
  exit 0
fi

# ---- Download images locally ----
CACHE="timelapse_cache_${TARGET_MONTH}"
mkdir -p "$CACHE"

echo "📥 Downloading images..."
i=0
while IFS= read -r path; do
  name=$(basename "$path")
  curl -s -X POST https://content.dropboxapi.com/2/files/download \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\": \"${path}\"}" \
    -o "${CACHE}/${name}"
  i=$((i+1))
  if (( i % 200 == 0 )); then echo "  ...$i downloaded"; fi
done < filelist.txt
echo "✅ Downloaded $i images"

# ---- Build ffmpeg input list (concat demuxer) ----
FFLIST="${CACHE}/ffmpeg_list.txt"
> "$FFLIST"
# Use only files that actually downloaded (defensive)
find "$CACHE" -maxdepth 1 -type f -name "*.jpg" | sort | awk '{print "file \x27"$0"\x27"}' > "$FFLIST"

# Recount frames we’ll actually use
FRAME_COUNT=$(wc -l < "$FFLIST" | tr -d ' ')
echo "🎛  Frame count available: ${FRAME_COUNT}"

# ---- Fixed 60 fps regardless of frame count ----
FPS=60
DECIMATED_LIST="$FFLIST"
echo "🎬 Using constant 60 fps with ${FRAME_COUNT} frames (duration ≈ $(awk "BEGIN{print $FRAME_COUNT/60}") s)"
echo "🎬 Using FPS=${FPS}, frames=${FRAME_COUNT}, duration≈$(( (FRAME_COUNT + FPS/2) / FPS ))s"

# ---- Make the video (1920px wide, keep aspect) ----
ffmpeg -y -f concat -safe 0 -i "$DECIMATED_LIST" \
  -r "$FPS" -vf "scale=1920:-2" "$OUT_MP4"

# ---- Upload video back to Dropbox (into that month’s folder) ----
echo "📤 Uploading ${OUT_MP4} to ${REMOTE_DIR}/"
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"${REMOTE_DIR}/${OUT_MP4}\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$OUT_MP4" >/dev/null

echo "✅ Timelapse uploaded: ${REMOTE_DIR}/${OUT_MP4}"

# ---- Cleanup ----
rm -rf "$CACHE" "$TMP_LIST_RESP" filelist.txt
