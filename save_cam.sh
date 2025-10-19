#!/bin/bash
set -e

# 👇 Replace this with your camera's public snapshot URL
URL="https://images.ambientweather.net/F8B3B780F0A5/latest.jpg"

# Working directory for temporary files
DIR="cache"
mkdir -p "$DIR"
TMP="$DIR/latest.jpg"
OUT="$DIR/$(date +%Y%m%d_%H%M%S).jpg"

# Dropbox app credentials (injected via GitHub Secrets)
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

# Get a short-lived access token from Dropbox
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# Download the latest camera image
curl -s -o "$TMP.new" "$URL"

# Compare new vs. last image
if [ ! -f "$TMP" ] || ! cmp -s "$TMP.new" "$TMP"; then
  mv "$TMP.new" "$OUT"
  cp "$OUT" "$TMP"
  DROPBOX_PATH="/WeatherCam/$(basename "$OUT")"
  curl -s -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\": \"$DROPBOX_PATH\", \"mode\": \"add\", \"autorename\": true}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @"$OUT"
  echo "Uploaded $(basename "$OUT")"
else
  rm "$TMP.new"
  echo "No change"
fi
