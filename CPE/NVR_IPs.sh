#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
NVR_IP="12.104.88.214"
USER="admin"
PASS="YQN1125-"

START_CAM=1
END_CAM=64

OUTFILE="camera_ips_${NVR_IP//[:.]/_}.txt"
TMPFILE="$(mktemp)"

# Extract first occurrence of a tag value
xml_get_tag() {
  local tag="$1"
  sed -n "s/.*<${tag}>\\([^<]*\\)<\\/${tag}>.*/\\1/p" | head -n 1
}

echo "Collecting camera IPs from NVR ${NVR_IP} ..."
> "$TMPFILE"

for cam in $(seq "$START_CAM" "$END_CAM"); do
  url="http://${NVR_IP}/ISAPI/ContentMgmt/InputProxy/channels/${cam}"

  if xml=$(curl -sS --anyauth -u "${USER}:${PASS}" "$url"); then
    ip=$(printf '%s' "$xml" | tr -d '\n' | xml_get_tag "ipAddress" || true)
    if [[ -n "$ip" ]]; then
      echo "$ip" >> "$TMPFILE"
      echo "Cam ${cam}: $ip"
    fi
  else
    echo "Cam ${cam}: metadata fetch failed"
  fi
done

# Deduplicate and save
sort -u "$TMPFILE" > "$OUTFILE"
rm -f "$TMPFILE"

echo
echo "Done ✅"
echo "IP list saved to: $OUTFILE"