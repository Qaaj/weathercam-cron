#!/bin/bash
set -e
export TZ="America/Halifax"

# ---------------------------------------------------------------------
# Skip nighttime (6 AM–8 PM Halifax)
hour=$(date +%H)
if [ "$hour" -lt 6 ] || [ "$hour" -ge 20 ]; then
  echo "Nighttime in Nova Scotia ($hour h) – skipping run."
  exit 0
fi

# ---------------------------------------------------------------------
# Environment variables from GitHub Secrets
CAM_URL="$CAM_URL"
AMBIENT_APP_KEY="$AMBIENT_APP_KEY"
AMBIENT_API_KEY="$AMBIENT_API_KEY"
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

DATA_URL="https://api.ambientweather.net/v1/devices?applicationKey=$AMBIENT_APP_KEY&apiKey=$AMBIENT_API_KEY"

DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMG_FILE="$DIR/${TIMESTAMP}.jpg"
JSON_FILE="$DIR/${TIMESTAMP}.json"
LATEST_IMG="$DIR/latest.jpg"

# ---------------------------------------------------------------------
# Dropbox access token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# ---------------------------------------------------------------------
# Download the latest camera image and weather data
curl -s -o "$IMG_FILE" "$CAM_URL"
curl -s -o "$JSON_FILE" "$DATA_URL"

# ---------------------------------------------------------------------
# Attempt to download the previous latest.jpg from Dropbox
echo "Fetching latest.jpg from Dropbox..."
HTTP_CODE=$(curl -L -s -w "%{http_code}" -o "$LATEST_IMG" \
  -X POST https://content.dropboxapi.com/2/files/download \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header 'Dropbox-API-Arg: {"path": "/WeatherCam/latest.jpg"}' )

if [ "$HTTP_CODE" != "200" ]; then
  echo "⚠️  Dropbox download failed (HTTP $HTTP_CODE)"
  cat "$LATEST_IMG" || true
  rm -f "$LATEST_IMG"
else
  echo "✅ latest.jpg downloaded successfully ($(stat -c%s "$LATEST_IMG") bytes)"
fi

# ---------------------------------------------------------------------
# Compare via SHA-256 hash (exact byte match)
SHOULD_UPLOAD=1
if [ -f "$LATEST_IMG" ]; then
  HASH_NEW=$(sha256sum "$IMG_FILE" | cut -d' ' -f1)
  HASH_OLD=$(sha256sum "$LATEST_IMG" | cut -d' ' -f1)
  echo "New image hash : $HASH_NEW"
  echo "Prev image hash: $HASH_OLD"
  if [ "$HASH_NEW" = "$HASH_OLD" ]; then
    echo "Image identical – skipping upload."
    SHOULD_UPLOAD=0
  fi
fi

# ---------------------------------------------------------------------
# Upload new data if the image differs
if [ "$SHOULD_UPLOAD" -eq 1 ]; then
  echo "Uploading new image and JSON..."

  # Upload timestamped image
  curl -s -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/${TIMESTAMP}.jpg\", \"mode\": \"add\", \"autorename\": true}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @"$IMG_FILE"

  # Upload timestamped JSON
  curl -s -X POST https://content.dropboxapi.com/2/files/upload \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/data/${TIMESTAMP}.json\", \"mode\": \"add\", \"autorename\": true}" \
    --header "Content-Type: application/octet-stream" \
    --data-binary @"$JSON_FILE"

  # Overwrite latest versions
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

  echo "✅ Uploaded ${TIMESTAMP}.jpg and ${TIMESTAMP}.json"
fi

# ---------------------------------------------------------------------
# Cleanup
rm -rf "$DIR"
echo "Done (Nova Scotia local time)"
