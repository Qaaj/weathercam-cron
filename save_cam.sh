#!/bin/bash
set -e
export TZ="America/Halifax"


# Get local hour (00–23)
hour=$(date +%H)

# Skip if before 6 AM or after 8 PM
if [ "$hour" -lt 6 ] || [ "$hour" -ge 20 ]; then
  echo "Nighttime in Nova Scotia ($hour h) – skipping run."
  exit 0
fi

# Camera and AmbientWeather API endpoints
CAM_URL="$CAM_URL"
DATA_URL="https://rt.ambientweather.net/v1/devices?applicationKey=$AMBIENT_APP_KEY&apiKey=$AMBIENT_API_KEY"

DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMG_FILE="$DIR/${TIMESTAMP}.jpg"
JSON_FILE="$DIR/${TIMESTAMP}.json"

# Dropbox app credentials (from secrets)
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

# Get a short-lived Dropbox access token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# Download camera image and AmbientWeather JSON
curl -s -o "$IMG_FILE" "$CAM_URL"
curl -s -o "$JSON_FILE" "$DATA_URL"

# Upload image
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

# Optional cleanup
rm -rf "$DIR"

echo "Uploaded ${TIMESTAMP}.jpg and ${TIMESTAMP}.json"
