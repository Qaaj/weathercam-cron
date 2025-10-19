#!/bin/bash
set -e
export TZ="America/Halifax"
# ---------------------------------------------------------------------
# Location: Antigonish, Nova Scotia
LAT="45.6217"
LON="-61.9981"

# ---------------------------------------------------------------------
# Default fallback times (6 AM – 8 PM Halifax)
SUNRISE_FALLBACK=6
SUNSET_FALLBACK=20

# ---------------------------------------------------------------------
echo "Fetching sunrise/sunset for Antigonish..."
API_URL="https://api.sunrise-sunset.org/json?lat=${LAT}&lng=${LON}&formatted=0"

if RESPONSE=$(curl -s --max-time 10 "$API_URL") && echo "$RESPONSE" | grep -q '"status":"OK"'; then
  SUNRISE_UTC=$(echo "$RESPONSE" | jq -r '.results.sunrise')
  SUNSET_UTC=$(echo "$RESPONSE" | jq -r '.results.sunset')
  SUNRISE_HOUR=$(date -d "$SUNRISE_UTC" +%H 2>/dev/null || echo "$SUNRISE_FALLBACK")
  SUNSET_HOUR=$(date -d "$SUNSET_UTC" +%H 2>/dev/null || echo "$SUNSET_FALLBACK")
  echo "Sunrise (local): ${SUNRISE_HOUR}h, Sunset (local): ${SUNSET_HOUR}h"
else
  echo "⚠️ Could not fetch sunrise/sunset — using fallback (${SUNRISE_FALLBACK}–${SUNSET_FALLBACK})."
  SUNRISE_HOUR=$SUNRISE_FALLBACK
  SUNSET_HOUR=$SUNSET_FALLBACK
fi

hour=$(date +%H)

# ---------------------------------------------------------------------
# Secrets and setup
CAM_URL="$CAM_URL"
AMBIENT_APP_KEY="$AMBIENT_APP_KEY"
AMBIENT_API_KEY="$AMBIENT_API_KEY"
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"
PG_CONN="$PG_CONN"

DATA_URL="https://api.ambientweather.net/v1/devices?applicationKey=$AMBIENT_APP_KEY&apiKey=$AMBIENT_API_KEY"

DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
IMG_FILE="$DIR/${TIMESTAMP}.jpg"
JSON_FILE="$DIR/${TIMESTAMP}.json"
LATEST_IMG="$DIR/latest.jpg"

# ---------------------------------------------------------------------
# Always fetch JSON data
curl -s -o "$JSON_FILE" "$DATA_URL"

# ---------------------------------------------------------------------
# Always insert into Supabase
if [ -n "$PG_CONN" ]; then
  echo "Inserting weather data into Supabase..."
  JSON=$(cat "$JSON_FILE")

  psql "$PG_CONN" <<'SQL'
  WITH rec AS (
    SELECT jsonb_array_elements(:'JSON'::jsonb)->'lastData' AS ld
  )
  INSERT INTO weather_lastdata (ts, payload)
  SELECT
    to_timestamp((ld->>'dateutc')::bigint / 1000),
    ld
  FROM rec
  ON CONFLICT (ts) DO NOTHING;
SQL
else
  echo "⚠️ PG_CONN not set — skipping database insert."
fi

# ---------------------------------------------------------------------
# Always upload the JSON file to Dropbox (data/latest.json)
echo "Uploading JSON to Dropbox..."
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/data/${TIMESTAMP}.json\", \"mode\": \"add\", \"autorename\": true}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$JSON_FILE"

curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/data/latest.json\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$JSON_FILE"

# ---------------------------------------------------------------------
# Only handle the image if it's daytime
if [ "$hour" -ge "$SUNRISE_HOUR" ] && [ "$hour" -lt "$SUNSET_HOUR" ]; then
  echo "Daytime ($hour h) – processing camera image."

  curl -s -o "$IMG_FILE" "$CAM_URL"

  echo "Fetching latest.jpg from Dropbox..."
  HTTP_CODE=$(curl -L -s -w "%{http_code}" -o "$LATEST_IMG" \
    -X POST https://content.dropboxapi.com/2/files/download \
    --header "Authorization: Bearer $ACCESS_TOKEN" \
    --header 'Dropbox-API-Arg: {"path": "/WeatherCam/latest.jpg"}' )

  if [ "$HTTP_CODE" != "200" ]; then
    echo "⚠️ Dropbox download failed (HTTP $HTTP_CODE)"
    rm -f "$LATEST_IMG"
  else
    echo "✅ latest.jpg downloaded ($(stat -c%s "$LATEST_IMG") bytes)"
  fi

  SHOULD_UPLOAD=1
  if [ -f "$LATEST_IMG" ]; then
    HASH_NEW=$(sha256sum "$IMG_FILE" | cut -d' ' -f1)
    HASH_OLD=$(sha256sum "$LATEST_IMG" | cut -d' ' -f1)
    echo "New hash: $HASH_NEW"
    echo "Old hash: $HASH_OLD"
    if [ "$HASH_NEW" = "$HASH_OLD" ]; then
      echo "Image identical – skipping upload."
      SHOULD_UPLOAD=0
    fi
  fi

  if [ "$SHOULD_UPLOAD" -eq 1 ]; then
    echo "Uploading new image..."
    curl -s -X POST https://content.dropboxapi.com/2/files/upload \
      --header "Authorization: Bearer $ACCESS_TOKEN" \
      --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/${TIMESTAMP}.jpg\", \"mode\": \"add\", \"autorename\": true}" \
      --header "Content-Type: application/octet-stream" \
      --data-binary @"$IMG_FILE"

    curl -s -X POST https://content.dropboxapi.com/2/files/upload \
      --header "Authorization: Bearer $ACCESS_TOKEN" \
      --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/latest.jpg\", \"mode\": \"overwrite\"}" \
      --header "Content-Type: application/octet-stream" \
      --data-binary @"$IMG_FILE"

    echo "✅ Uploaded ${TIMESTAMP}.jpg"
  fi
else
  echo "Nighttime ($hour h) – skipping photo upload."
fi

# ---------------------------------------------------------------------
# Cleanup
rm -rf "$DIR"
echo "Done (Nova Scotia local time)"
