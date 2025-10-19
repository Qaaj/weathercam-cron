#!/bin/bash
set -e
export TZ="America/Halifax"

# ---------------------------------------------------------------------
# Secrets
APP_KEY="$DROPBOX_APP_KEY"
APP_SECRET="$DROPBOX_APP_SECRET"
REFRESH_TOKEN="$DROPBOX_REFRESH_TOKEN"
PG_CONN="$PG_CONN"
BIRDWEATHER_ID="$BIRDWEATHER_ID"

DATESTAMP=$(date +%Y%m%d)
DAY_SUMMARY_FILE="$DIR/bird_summary_${DATESTAMP}.json"

# ---------------------------------------------------------------------
# Get Dropbox token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# ---------------------------------------------------------------------
# Fetch BirdWeather detections (500 latest)
QUERY="{ station(id: ${BIRDWEATHER_ID}) { detections(last: 500) { edges { node { id confidence timestamp species { id commonName scientificName } } } } } }"
echo "Fetching BirdWeather detections for station ${BIRDWEATHER_ID}..."
DATA=$(curl -s -X POST https://app.birdweather.com/graphql \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"$QUERY\"}")

# ---------------------------------------------------------------------
# Save raw JSON locally
DIR="cache"
mkdir -p "$DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_FILE="$DIR/bird_detections_${TIMESTAMP}.json"
echo "$DATA" > "$DAY_SUMMARY_FILE"

# Upload (will overwrite same file until date changes)
curl -s -X POST https://content.dropboxapi.com/2/files/upload \
  --header "Authorization: Bearer $ACCESS_TOKEN" \
  --header "Dropbox-API-Arg: {\"path\": \"/WeatherCam/bird_summary_${DATESTAMP}.json\", \"mode\": \"overwrite\"}" \
  --header "Content-Type: application/octet-stream" \
  --data-binary @"$DAY_SUMMARY_FILE"

echo "✅ Uploaded raw detections (${TIMESTAMP})"

# ---------------------------------------------------------------------
# Insert detections into Supabase (deduplicated)
if [ -n "$PG_CONN" ]; then
  echo "Inserting BirdWeather detections into Supabase..."
  JSON=$(cat "$OUT_FILE")

  echo "$JSON" | psql "$PG_CONN" -v ON_ERROR_STOP=1 -v jsondata="$(cat)" <<'SQL'
WITH dets AS (
  SELECT jsonb_array_elements(:'jsondata'::jsonb #> '{data,station,detections,edges}') AS edge
)
INSERT INTO bird_detections (detection_id, ts, payload)
SELECT
  edge->'node'->>'id' AS detection_id,
  (edge->'node'->>'timestamp')::timestamptz AS ts,
  edge->'node' AS payload
FROM dets
ON CONFLICT (detection_id) DO NOTHING;
SQL

  echo "✅ Inserted new detections into Supabase (skipped existing)"
else
  echo "⚠️ PG_CONN not set — skipping database insert."
fi

# ---------------------------------------------------------------------
# Cleanup
rm -rf "$DIR"
echo "Done (Nova Scotia local time)"
