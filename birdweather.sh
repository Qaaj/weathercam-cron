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

# ---------------------------------------------------------------------
# Get Dropbox token
ACCESS_TOKEN=$(curl -s -u "$APP_KEY:$APP_SECRET" \
  -d "grant_type=refresh_token&refresh_token=$REFRESH_TOKEN" \
  https://api.dropboxapi.com/oauth2/token | jq -r .access_token)

# ---------------------------------------------------------------------
# Prepare directories and filenames
DIR="cache"
mkdir -p "$DIR"
DATESTAMP=$(date +%Y%m%d)
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DAY_SUMMARY_FILE="$DIR/bird_summary_${DATESTAMP}.json"

# ---------------------------------------------------------------------
# Fetch BirdWeather detections (last 100)
QUERY="{ station(id: ${BIRDWEATHER_ID}) { detections(last: 100) { edges { node { id confidence timestamp species { id commonName scientificName } } } } } }"
echo "Fetching BirdWeather detections for station ${BIRDWEATHER_ID}..."
DATA=$(curl -s -X POST https://app.birdweather.com/graphql \
  -H "Content-Type: application/json" \
  -d "{\"query\": \"$QUERY\"}")

# ---------------------------------------------------------------------
# Save and upload the daily summary file (overwrites same date)
echo "$DATA" > "$DAY_SUMMARY_FILE"

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
  JSON="$DATA"

  echo "$JSON" | psql "$PG_CONN" -v ON_ERROR_STOP=1 -v jsondata="$JSON" <<'SQL'
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
  echo "⚠️  PG_CONN not set — skipping database insert."
fi

# ---------------------------------------------------------------------
# Cleanup
rm -rf "$DIR"
echo "Done (Nova Scotia local time)"
