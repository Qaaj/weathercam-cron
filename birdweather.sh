#!/bin/bash
set -e
export TZ="America/Halifax"

# ---------------------------------------------------------------------
# Dropbox credentials
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"

# BirdWeather station ID (passed as a secret)
STATION_ID="$BIRDWEATHER_ID"

# ---------------------------------------------------------------------
# Get Dropbox access token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# ---------------------------------------------------------------------
# GraphQL query (station ID interpolated)
QUERY="{ station(id: ${STATION_ID}) { id name timeOfDayDetectionCounts { count speciesId species { id commonName scientificName } } } }"

# ---------------------------------------------------------------------
# Run query and save raw JSON
DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_FILE="$DIR/birdweather_${TIMESTAMP}.json"

echo "Fetching BirdWeather data for station ID ${STATION_ID}..."
HTTP_CODE=$(curl -s -w "%{http_code}" -o "$OUT_FILE" \
  -X POST https://app.birdweather.com/graphql \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"$QUERY\"}")

if [ "$HTTP_CODE" != "200" ]; then
  echo "⚠️  BirdWeather API returned HTTP $HTTP_CODE"
else
  echo "✅ GraphQL query successful, response saved to $OUT_FILE"
fi

# ---------------------------------------------------------------------
# Upload to Dropbox (timestamped + latest)
echo "Uploading to Dropbox..."
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/birdweather_${TIMESTAMP}.json\", \"mode\": \"add\", \"autorename\": true}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$OUT_FILE"

curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/birdweather_latest.json\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$OUT_FILE"

echo "✅ Uploaded raw BirdWeather GraphQL output (${TIMESTAMP})"
rm -rf "$DIR"
