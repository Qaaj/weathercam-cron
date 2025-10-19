#!/bin/bash
set -e
export TZ="America/Halifax"

hour=$(date +%H)
if [ "$hour" -lt 6 ] || [ "$hour" -ge 20 ]; then
  echo "Nighttime in Nova Scotia ($hour h) – skipping run."
  exit 0
fi

# Secrets
CAM_URL="$CAM_URL"
DATA_URL="https://api.ambientweather.net/v1/devices?applicationKey=$AMBIENT_APP_KEY&apiKey=$AMBIENT_API_KEY"
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMG_FILE="$DIR/${TIMESTAMP}.jpg"
JSON_FILE="$DIR/${TIMESTAMP}.json"
LATEST_IMG="$DIR/latest.jpg"

# Dropbox short-lived access token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# Download current image and data
curl -s -o "$IMG_FILE" "$CAM_URL"
curl -s -o "$JSON_FILE" "$DATA_URL"

# Download previous latest.jpg from Dropbox (if exists)
curl -s -X POST https://content.dropboxapi.com/2/files/download \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/latest.jpg\"}" \
  -o "$LATEST_IMG" || true

# Compare to previous
if [ -f "$LATEST_IMG" ] && cmp -s "$IMG_FILE" "$LATEST_IMG"; then
  echo "Image identical to latest.jpg – skipping upload."
  rm -rf "$DIR"
  exit 0
fi

# Upload new image
DROPBOX_PATH_IMG="/WeatherCam/${TIMESTAMP}.jpg"
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"$DROPBOX_PATH_IMG\", \"mode\": \"add\", \"autorename\": true}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$IMG_FILE"

# Upload JSON
DROPBOX_PATH_JSON="/WeatherCam/data/${TIMESTAMP}.json"
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"$DROPBOX_PATH_JSON\", \"mode\": \"add\", \"autorename\": true}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$JSON_FILE"

# Upload current as latest.jpg and latest.json
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/latest.jpg\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$IMG_FILE"

curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/data/latest.json\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$JSON_FILE"

rm -rf "$DIR"

echo "Uploaded ${TIMESTAMP}.jpg and ${TIMESTAMP}.json (Nova Scotia local time)"
